# Claude Code Telegram Notifier

A bidirectional notification system that sends push notifications to your iPhone via Telegram when Claude Code needs input, and allows you to respond directly from Telegram.

Built for developers running Claude Code on remote VMs who want to stay productive while away from their terminal.

## Features

- **Push Notifications**: Receive instant Telegram notifications when Claude needs input
- **Two Hook Types**:
  - `AskUserQuestion` - Structured questions with predefined options
  - `Stop` - When Claude finishes and waits for your next prompt
- **Quick Replies**: Tap inline buttons to select from predefined options
- **Custom Responses**: Type any response directly in Telegram
- **Bidirectional**: Your replies are automatically injected into Claude's tmux session
- **Secure**: Credentials are AES-256 encrypted at rest
- **One-liner Install**: Set up everything with a single command
- **Lightweight**: Minimal resource footprint, runs as a systemd service

## Architecture

```
┌─────────────────┐    PreToolUse Hook    ┌─────────────────┐
│   Claude Code   │ ───────────────────── │  notify_hook.sh │
│ (tmux session)  │                       └────────┬────────┘
└────────▲────────┘                                │
         │                                         │ HTTP POST
         │ tmux send-keys                          ▼
         │                                ┌─────────────────┐
┌─────────────────┐    Telegram API       │  telegram_bot.py│
│     iPhone      │ ◄───────────────────► │  (Python daemon)│
│ (Telegram App)  │    Long Polling       └─────────────────┘
└─────────────────┘
```

## Quick Start

### One-Liner Installation

```bash
curl -fsSL https://raw.githubusercontent.com/PABannier/claude-telegram-bot/main/install.sh | bash
```

The installer will:
1. Check and install dependencies
2. Guide you through creating a Telegram bot
3. Auto-detect your Chat ID
4. Securely encrypt and store your credentials
5. Configure Claude Code hooks
6. Set up and start the systemd service

That's it! You'll be ready to receive notifications in minutes.

## Prerequisites

Before running the installer, ensure you have:

- Python 3.8+ with venv module
- tmux (for session management)
- jq (for JSON parsing)
- curl and openssl (usually pre-installed)

### Install Dependencies

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-full tmux jq curl
```

**macOS:**
```bash
brew install python tmux jq
```

## Manual Setup Guide

If you prefer manual installation or the one-liner doesn't work:

### Step 1: Create a Telegram Bot

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Start a chat and send `/newbot`
3. Follow the prompts to name your bot
4. **Save the bot token** - it looks like:
   ```
   123456789:ABCdefGHIjklmnOPQRSTuvwxyz
   ```

### Step 2: Get Your Chat ID

1. Start a conversation with your new bot (send any message like "hello")
2. The installer will auto-detect it, or find it manually at:
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
3. Look for `"chat":{"id":123456789}` in the response

### Step 3: Run the Installer

```bash
# Clone the repository
git clone https://github.com/PABannier/claude-telegram-bot.git
cd claude-telegram-bot

# Run the installer
./install.sh
```

The interactive installer will prompt you for:
- Your Telegram Bot Token (validated against Telegram API)
- Your Chat ID (auto-detected or manual entry)

### Step 4: Verify Installation

```bash
# Check service status
systemctl --user status claude-telegram

# View logs
journalctl --user -u claude-telegram -f
```

## Usage

### Testing the Setup

1. Start a tmux session:
   ```bash
   tmux new -s claude
   ```

2. Run Claude Code inside tmux:
   ```bash
   claude
   ```

3. Ask Claude something that triggers `AskUserQuestion`:
   ```
   What programming language should I use for a new web project?
   ```

4. You should receive a Telegram notification!

### Responding to Questions

**Option 1: Tap a Button**
- Questions with predefined options show inline buttons
- Tap any button to send that response to Claude

**Option 2: Type a Reply**
- Reply to the notification message with your custom answer
- Or simply send a message to the bot (it answers the most recent question)

### Message Format

When Claude asks a question, you'll receive:

```
*Claude needs input*
_Project: my-web-app_

*Q1: Which database should we use?*
  1. PostgreSQL - Robust, full-featured relational database
  2. SQLite - Lightweight, file-based database
  3. MongoDB - Document-based NoSQL database

_Reply to this message or tap a button_
```

## Service Management

**Linux (systemd):**
```bash
# Start the service
systemctl --user start claude-telegram

# Stop the service
systemctl --user stop claude-telegram

# Restart the service
systemctl --user restart claude-telegram

# View status
systemctl --user status claude-telegram

# View logs
journalctl --user -u claude-telegram -f
```

**macOS / Manual:**
```bash
# Start manually
~/.claude-telegram-notifier/decrypt_config.sh ~/.claude-telegram-notifier/venv/bin/python ~/.claude-telegram-notifier/telegram_bot.py

# Run in background
nohup ~/.claude-telegram-notifier/decrypt_config.sh ~/.claude-telegram-notifier/venv/bin/python ~/.claude-telegram-notifier/telegram_bot.py > /tmp/claude-telegram.log 2>&1 &
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TELEGRAM_BOT_TOKEN` | Your Telegram bot token | Required |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID | Required |
| `HTTP_PORT` | Local HTTP server port | `8642` |
| `HTTP_HOST` | Local HTTP server host | `127.0.0.1` |
| `QUESTION_TIMEOUT_SECONDS` | Auto-cleanup timeout | `3600` |

### Claude Code Hook Configuration

The installer automatically adds this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-telegram-notifier/notify_hook.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-telegram-notifier/stop_hook.sh"
          }
        ]
      }
    ]
  }
}
```

## File Structure

```
~/.claude-telegram-notifier/
├── telegram_bot.py      # Main daemon process
├── notify_hook.sh       # Hook for AskUserQuestion (structured questions)
├── stop_hook.sh         # Hook for Stop (Claude waiting for input)
├── decrypt_config.sh    # Credential decryption wrapper
├── .config.enc          # Encrypted credentials (AES-256)
├── .encryption_key      # Encryption key (chmod 600)
├── config.env           # Non-sensitive configuration
├── requirements.txt     # Python dependencies
└── venv/                # Python virtual environment
    └── bin/python       # Isolated Python interpreter

~/.config/systemd/user/
└── claude-telegram.service  # Systemd service unit

~/.claude/settings.json  # Claude Code configuration (hooks)
```

## Security

### Credential Storage

Your Telegram credentials are protected using:

- **AES-256-CBC encryption** with PBKDF2 key derivation
- **Randomly generated encryption key** stored with `chmod 600`
- **Runtime decryption** - credentials are only decrypted when the daemon starts
- **No plaintext storage** - tokens never written to disk unencrypted

### Network Security

- HTTP server binds to `127.0.0.1` only (not accessible from network)
- Telegram bot rejects messages from unauthorized chat IDs
- All Telegram API communication over HTTPS

## Troubleshooting

### No notifications received

1. **Check the service is running:**
   ```bash
   systemctl --user status claude-telegram
   ```

2. **Check the logs:**
   ```bash
   journalctl --user -u claude-telegram -f
   ```

3. **Test Telegram connectivity:**
   ```bash
   # This should send a test message
   ~/.claude-telegram-notifier/decrypt_config.sh bash -c \
     'curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
       -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=Test"'
   ```

### Response not reaching Claude

1. **Ensure Claude is running in tmux:**
   ```bash
   tmux list-sessions
   ```

2. **Test tmux send-keys manually:**
   ```bash
   tmux send-keys -t <session>:<window>.<pane> "test" Enter
   ```

3. **Check hook script permissions:**
   ```bash
   ls -la ~/.claude-telegram-notifier/notify_hook.sh
   # Should show executable: -rwx------
   ```

### "Unauthorized" message in Telegram

Your Chat ID may be incorrect. Re-run the installer or manually check:
```bash
# After sending a message to your bot
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'
```

### Service won't start

1. **Check for errors:**
   ```bash
   journalctl --user -u claude-telegram --no-pager -n 50
   ```

2. **Run manually to see errors:**
   ```bash
   ~/.claude-telegram-notifier/decrypt_config.sh ~/.claude-telegram-notifier/venv/bin/python ~/.claude-telegram-notifier/telegram_bot.py
   ```

3. **Verify Python dependencies:**
   ```bash
   ~/.claude-telegram-notifier/venv/bin/pip install pyTelegramBotAPI python-dotenv
   ```

## Uninstalling

Use the built-in uninstaller:

```bash
curl -fsSL https://raw.githubusercontent.com/PABannier/claude-telegram-bot/main/install.sh | bash -s -- --uninstall
```

Or manually:

```bash
# Stop and disable the service
systemctl --user stop claude-telegram
systemctl --user disable claude-telegram

# Remove files
rm -rf ~/.claude-telegram-notifier
rm -f ~/.config/systemd/user/claude-telegram.service
systemctl --user daemon-reload

# Remove hook from Claude settings
# Edit ~/.claude/settings.json and remove the AskUserQuestion hook
```

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

Inspired by [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) which demonstrated the concept using Poke webhooks.
