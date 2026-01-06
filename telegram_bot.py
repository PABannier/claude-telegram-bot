#!/usr/bin/env python3
"""
Claude Code Telegram Notifier

A daemon that:
1. Receives notifications from Claude Code's PreToolUse hook when AskUserQuestion is called
2. Sends formatted questions to Telegram with inline keyboard buttons
3. Receives user responses from Telegram
4. Injects responses into Claude's tmux session via tmux send-keys
"""

import os
import json
import time
import logging
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from dataclasses import dataclass, field
from typing import Optional, Dict, List
from dotenv import load_dotenv

import telebot
from telebot import types

# Load environment variables
load_dotenv(os.path.join(os.path.dirname(__file__), 'config.env'))


def decrypt_value(encrypted: str, key: str) -> str:
    """Decrypt an AES-256-CBC encrypted value"""
    try:
        result = subprocess.run(
            ['openssl', 'enc', '-aes-256-cbc', '-pbkdf2', '-base64', '-A', '-d', '-pass', f'pass:{key}'],
            input=encrypted.encode(),
            capture_output=True
        )
        if result.returncode == 0:
            return result.stdout.decode().strip()
    except Exception:
        pass
    return ''


def load_credentials() -> tuple[str, int]:
    """Load credentials from environment or decrypt from .config.enc"""
    # First try environment variables (set by decrypt_config.sh wrapper)
    bot_token = os.getenv('TELEGRAM_BOT_TOKEN', '')
    chat_id_str = os.getenv('TELEGRAM_CHAT_ID', '')

    # If not found, decrypt directly from .config.enc
    if not bot_token or not chat_id_str:
        install_dir = os.path.dirname(__file__)
        key_file = os.path.join(install_dir, '.encryption_key')
        config_file = os.path.join(install_dir, '.config.enc')

        if os.path.exists(key_file) and os.path.exists(config_file):
            with open(key_file, 'r') as f:
                key = f.read().strip()

            # Parse the encrypted config file (handles multi-line base64 values)
            encrypted_values = {}
            current_key = None
            with open(config_file, 'r') as f:
                for line in f:
                    line = line.rstrip('\n\r')
                    if '=' in line and not line.startswith('#'):
                        k, v = line.split('=', 1)
                        encrypted_values[k] = v
                        current_key = k
                    elif current_key and line and not line.startswith('#'):
                        # Continuation of previous value (multi-line base64)
                        encrypted_values[current_key] += line

            if not bot_token:
                encrypted_token = encrypted_values.get('ENCRYPTED_TELEGRAM_BOT_TOKEN', '')
                if encrypted_token:
                    bot_token = decrypt_value(encrypted_token, key)

            if not chat_id_str:
                encrypted_chat_id = encrypted_values.get('ENCRYPTED_TELEGRAM_CHAT_ID', '')
                if encrypted_chat_id:
                    chat_id_str = decrypt_value(encrypted_chat_id, key)

    chat_id = int(chat_id_str) if chat_id_str else 0
    return bot_token, chat_id


# Configuration
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID = load_credentials()
HTTP_PORT = int(os.getenv('HTTP_PORT', '8642'))
HTTP_HOST = os.getenv('HTTP_HOST', '127.0.0.1')
QUESTION_TIMEOUT_SECONDS = int(os.getenv('QUESTION_TIMEOUT_SECONDS', '3600'))

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('claude-telegram')

# Initialize Telegram bot
if not TELEGRAM_BOT_TOKEN:
    logger.error("TELEGRAM_BOT_TOKEN not set in config.env")
    exit(1)

bot = telebot.TeleBot(TELEGRAM_BOT_TOKEN)


@dataclass
class PendingQuestion:
    """Tracks a question awaiting response"""
    question_id: str
    session_id: str
    tmux_location: str
    questions: List[dict]
    timestamp: float
    telegram_message_id: int
    cwd: str = ""
    answered: bool = False
    answers: Dict[int, str] = field(default_factory=dict)  # question_idx -> selected answer


class SessionStore:
    """Thread-safe store for pending questions"""

    def __init__(self):
        self._lock = threading.Lock()
        self.pending: Dict[str, PendingQuestion] = {}
        self._message_id_map: Dict[int, str] = {}  # telegram_message_id -> question_id

    def add_question(self, q: PendingQuestion) -> None:
        with self._lock:
            self.pending[q.question_id] = q
            self._message_id_map[q.telegram_message_id] = q.question_id
            logger.info(f"Added question {q.question_id} for tmux {q.tmux_location}")

    def get_by_message_id(self, msg_id: int) -> Optional[PendingQuestion]:
        with self._lock:
            question_id = self._message_id_map.get(msg_id)
            if question_id:
                return self.pending.get(question_id)
            return None

    def get_latest_unanswered(self) -> Optional[PendingQuestion]:
        """Get the most recent unanswered question"""
        with self._lock:
            unanswered = [q for q in self.pending.values() if not q.answered]
            if unanswered:
                return max(unanswered, key=lambda q: q.timestamp)
            return None

    def mark_answered(self, question_id: str) -> None:
        with self._lock:
            if question_id in self.pending:
                self.pending[question_id].answered = True
                logger.info(f"Marked question {question_id} as answered")

    def cleanup_old(self, max_age_seconds: int = 3600) -> None:
        """Remove questions older than max_age_seconds"""
        with self._lock:
            now = time.time()
            to_remove = [
                qid for qid, q in self.pending.items()
                if (now - q.timestamp) > max_age_seconds
            ]
            for qid in to_remove:
                q = self.pending.pop(qid, None)
                if q:
                    self._message_id_map.pop(q.telegram_message_id, None)
                    logger.info(f"Cleaned up old question {qid}")


# Global session store
store = SessionStore()


def format_telegram_message(questions: List[dict], cwd: str) -> str:
    """Format questions for Telegram readability"""
    project_name = os.path.basename(cwd) if cwd else "Unknown"
    lines = [f"*Claude needs input*\n_Project: {project_name}_\n"]

    for i, q in enumerate(questions):
        question_text = q.get('question', 'No question text')
        lines.append(f"\n*Q{i+1}: {question_text}*")

        options = q.get('options', [])
        for j, opt in enumerate(options):
            label = opt.get('label', f'Option {j+1}')
            description = opt.get('description', '')
            if description:
                lines.append(f"  {j+1}. {label} - {description}")
            else:
                lines.append(f"  {j+1}. {label}")

        if q.get('multiSelect'):
            lines.append("  _(Multiple selections allowed)_")

    lines.append("\n_Reply to this message or tap a button_")
    return "\n".join(lines)


def create_inline_keyboard(questions: List[dict], answers: Dict[int, str] = None) -> types.InlineKeyboardMarkup:
    """Create quick-reply buttons for all questions' options plus Submit"""
    markup = types.InlineKeyboardMarkup()
    answers = answers or {}
    multi_question = len(questions) > 1

    for q_idx, q in enumerate(questions):
        options = q.get('options', [])
        for opt_idx, opt in enumerate(options):
            label = opt.get('label', f'Option {opt_idx+1}')
            # Mark selected option with checkmark
            is_selected = answers.get(q_idx) == label
            prefix = "✓ " if is_selected else ""
            # Prefix with Q number if multiple questions
            if multi_question:
                display_label = f"{prefix}Q{q_idx+1}: {label}"
            else:
                display_label = f"{prefix}{label}"
            # Truncate if too long for Telegram button
            if len(display_label) > 40:
                display_label = display_label[:37] + "..."
            markup.add(types.InlineKeyboardButton(
                text=display_label,
                callback_data=f"ans_{q_idx}_{opt_idx}"
            ))

    # Add Submit button
    markup.add(types.InlineKeyboardButton(
        text="✅ Submit",
        callback_data="submit"
    ))

    return markup


def inject_response_to_tmux(tmux_location: str, response: str, send_enter: bool = True) -> bool:
    """Send response to Claude's tmux pane"""
    if not tmux_location or tmux_location == "unknown":
        logger.error("Unknown tmux location, cannot inject response")
        return False

    try:
        # Check if tmux session exists
        session_name = tmux_location.split(':')[0]
        result = subprocess.run(
            ['tmux', 'has-session', '-t', session_name],
            capture_output=True
        )
        if result.returncode != 0:
            logger.error(f"tmux session not found: {session_name}")
            return False

        # Escape special characters for tmux
        # We use send-keys with literal flag to avoid interpretation issues
        cmd = ['tmux', 'send-keys', '-t', tmux_location, '-l', response]
        subprocess.run(cmd, check=True)

        # Send Enter key separately
        if send_enter:
            cmd_enter = ['tmux', 'send-keys', '-t', tmux_location, 'Enter']
            subprocess.run(cmd_enter, check=True)

        logger.info(f"Injected response to tmux {tmux_location}")
        return True

    except subprocess.CalledProcessError as e:
        logger.error(f"tmux send-keys failed: {e}")
        return False
    except Exception as e:
        logger.error(f"Error injecting response: {e}")
        return False


def inject_multiple_responses_to_tmux(tmux_location: str, responses: List[str]) -> bool:
    """Send multiple responses to Claude's tmux pane, one per question, then submit"""
    if not tmux_location or tmux_location == "unknown":
        logger.error("Unknown tmux location, cannot inject responses")
        return False

    try:
        session_name = tmux_location.split(':')[0]
        result = subprocess.run(
            ['tmux', 'has-session', '-t', session_name],
            capture_output=True
        )
        if result.returncode != 0:
            logger.error(f"tmux session not found: {session_name}")
            return False

        for i, response in enumerate(responses):
            # Send the answer
            cmd = ['tmux', 'send-keys', '-t', tmux_location, '-l', response]
            subprocess.run(cmd, check=True)

            # Send Enter after each answer to select it
            cmd_enter = ['tmux', 'send-keys', '-t', tmux_location, 'Enter']
            subprocess.run(cmd_enter, check=True)

            # Small delay to let the UI process
            time.sleep(0.8)

        # Final Enter to submit all answers
        time.sleep(0.8)
        cmd_submit = ['tmux', 'send-keys', '-t', tmux_location, 'Enter']
        subprocess.run(cmd_submit, check=True)

        logger.info(f"Injected {len(responses)} responses to tmux {tmux_location} and submitted")
        return True

    except subprocess.CalledProcessError as e:
        logger.error(f"tmux send-keys failed: {e}")
        return False
    except Exception as e:
        logger.error(f"Error injecting responses: {e}")
        return False


class HookRequestHandler(BaseHTTPRequestHandler):
    """HTTP handler for incoming hook requests"""

    def log_message(self, format, *args):
        """Override to use our logger"""
        logger.debug(f"HTTP: {format % args}")

    def do_POST(self):
        path = self.path.rstrip('/')

        if path == '/notify':
            self._handle_notify()
        elif path == '/stop':
            self._handle_stop()
        else:
            # Default to notify for backwards compatibility
            self._handle_notify()

    def _handle_notify(self):
        """Handle AskUserQuestion notifications"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            # Extract fields from hook data
            session_id = data.get('session_id', 'unknown')
            tmux_location = data.get('tmux_location', 'unknown')
            tool_input = data.get('tool_input', {})
            questions = tool_input.get('questions', [])
            cwd = data.get('cwd', '')

            if not questions:
                logger.warning("No questions in hook data")
                self._send_response(400, {"error": "No questions provided"})
                return

            # Generate unique question ID
            question_id = f"{session_id}_{int(time.time() * 1000)}"

            # Format and send to Telegram
            message = format_telegram_message(questions, cwd)
            markup = create_inline_keyboard(questions)

            try:
                sent_msg = bot.send_message(
                    TELEGRAM_CHAT_ID,
                    message,
                    parse_mode='Markdown',
                    reply_markup=markup
                )

                # Store pending question
                store.add_question(PendingQuestion(
                    question_id=question_id,
                    session_id=session_id,
                    tmux_location=tmux_location,
                    questions=questions,
                    timestamp=time.time(),
                    telegram_message_id=sent_msg.message_id,
                    cwd=cwd
                ))

                self._send_response(200, {"status": "sent", "question_id": question_id})

            except Exception as e:
                logger.error(f"Failed to send Telegram message: {e}")
                self._send_response(500, {"error": str(e)})

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in request: {e}")
            self._send_response(400, {"error": "Invalid JSON"})
        except Exception as e:
            logger.error(f"Error handling request: {e}")
            self._send_response(500, {"error": str(e)})

    def _handle_stop(self):
        """Handle Stop hook - Claude finished and waiting for input"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            tmux_location = data.get('tmux_location', 'unknown')
            stop_reason = data.get('stop_reason', 'completed')

            # Generate unique ID
            stop_id = f"stop_{int(time.time() * 1000)}"

            # Format message
            message = f"*Claude is waiting for input*\n_Reason: {stop_reason}_\n\n_Reply to this message with your response_"

            try:
                sent_msg = bot.send_message(
                    TELEGRAM_CHAT_ID,
                    message,
                    parse_mode='Markdown'
                )

                # Store as a pending question (no options, just free text)
                store.add_question(PendingQuestion(
                    question_id=stop_id,
                    session_id="stop",
                    tmux_location=tmux_location,
                    questions=[],  # No structured questions
                    timestamp=time.time(),
                    telegram_message_id=sent_msg.message_id,
                    cwd=""
                ))

                self._send_response(200, {"status": "sent", "stop_id": stop_id})

            except Exception as e:
                logger.error(f"Failed to send Telegram stop message: {e}")
                self._send_response(500, {"error": str(e)})

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in stop request: {e}")
            self._send_response(400, {"error": "Invalid JSON"})
        except Exception as e:
            logger.error(f"Error handling stop request: {e}")
            self._send_response(500, {"error": str(e)})

    def _send_response(self, status: int, data: dict):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


# Telegram message handlers

@bot.message_handler(func=lambda m: m.chat.id == TELEGRAM_CHAT_ID)
def handle_message(message):
    """Handle text messages from authorized user"""
    response_text = message.text.strip()

    # Check if this is a reply to a question message
    if message.reply_to_message:
        pending = store.get_by_message_id(message.reply_to_message.message_id)
        if pending and not pending.answered:
            if inject_response_to_tmux(pending.tmux_location, response_text):
                store.mark_answered(pending.question_id)
                bot.reply_to(message, "Response sent to Claude")
            else:
                bot.reply_to(message, "Failed to send response - check tmux session")
            return

    # Not a reply - try to answer the most recent unanswered question
    pending = store.get_latest_unanswered()
    if pending:
        if inject_response_to_tmux(pending.tmux_location, response_text):
            store.mark_answered(pending.question_id)
            bot.reply_to(message, "Response sent to Claude")
        else:
            bot.reply_to(message, "Failed to send response - check tmux session")
    else:
        bot.reply_to(message, "No pending questions from Claude")


@bot.message_handler(func=lambda m: m.chat.id != TELEGRAM_CHAT_ID)
def handle_unauthorized(message):
    """Reject messages from unauthorized users"""
    logger.warning(f"Unauthorized message from chat_id: {message.chat.id}")
    bot.reply_to(message, "Unauthorized. This bot is private.")


@bot.callback_query_handler(func=lambda call: call.message.chat.id == TELEGRAM_CHAT_ID)
def handle_callback(call):
    """Handle inline button clicks"""
    pending = store.get_by_message_id(call.message.message_id)

    if not pending:
        bot.answer_callback_query(call.id, "Question expired")
        return

    if pending.answered:
        bot.answer_callback_query(call.id, "Already answered")
        return

    try:
        if call.data == "submit":
            # Submit all answers
            if not pending.answers:
                bot.answer_callback_query(call.id, "Select at least one answer first")
                return

            # Get answers in order
            responses = []
            for q_idx in range(len(pending.questions)):
                if q_idx in pending.answers:
                    responses.append(pending.answers[q_idx])

            if not responses:
                bot.answer_callback_query(call.id, "No answers selected")
                return

            if inject_multiple_responses_to_tmux(pending.tmux_location, responses):
                store.mark_answered(pending.question_id)
                bot.answer_callback_query(call.id, f"Sent {len(responses)} response(s)!")
                # Remove buttons after answering
                bot.edit_message_reply_markup(
                    call.message.chat.id,
                    call.message.message_id,
                    reply_markup=None
                )
            else:
                bot.answer_callback_query(call.id, "Failed to send - check tmux")

        elif call.data.startswith("ans_"):
            # Parse: ans_{question_idx}_{option_idx}
            parts = call.data.split('_')
            q_idx = int(parts[1])
            opt_idx = int(parts[2])

            options = pending.questions[q_idx].get('options', [])
            if opt_idx < len(options):
                answer = options[opt_idx].get('label', f'Option {opt_idx + 1}')
                pending.answers[q_idx] = answer

                # Update keyboard to show selection
                new_markup = create_inline_keyboard(pending.questions, pending.answers)
                bot.edit_message_reply_markup(
                    call.message.chat.id,
                    call.message.message_id,
                    reply_markup=new_markup
                )

                bot.answer_callback_query(call.id, f"Selected: {answer[:20]}")
            else:
                bot.answer_callback_query(call.id, "Invalid option")
        else:
            bot.answer_callback_query(call.id, "Unknown action")

    except (ValueError, IndexError) as e:
        logger.error(f"Error parsing callback data: {e}")
        bot.answer_callback_query(call.id, "Error processing response")


def run_http_server():
    """Run local HTTP server"""
    server = HTTPServer((HTTP_HOST, HTTP_PORT), HookRequestHandler)
    logger.info(f"HTTP server listening on {HTTP_HOST}:{HTTP_PORT}")
    server.serve_forever()


def cleanup_worker():
    """Background worker to clean up old questions"""
    while True:
        time.sleep(300)  # Check every 5 minutes
        store.cleanup_old(QUESTION_TIMEOUT_SECONDS)


def main():
    logger.info("Starting Claude Code Telegram Notifier")
    logger.info(f"Bot token: {TELEGRAM_BOT_TOKEN[:10]}...")
    logger.info(f"Authorized chat ID: {TELEGRAM_CHAT_ID}")

    # Start HTTP server in background thread
    http_thread = threading.Thread(target=run_http_server, daemon=True)
    http_thread.start()

    # Start cleanup worker in background
    cleanup_thread = threading.Thread(target=cleanup_worker, daemon=True)
    cleanup_thread.start()

    # Start Telegram polling (blocking)
    logger.info("Starting Telegram bot polling...")
    bot.infinity_polling(timeout=60, long_polling_timeout=60)


if __name__ == '__main__':
    main()
