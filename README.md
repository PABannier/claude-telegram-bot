# Claude Code Telegram Notifier

A bidirectional notification system that sends push notifications to your iPhone via Telegram when Claude Code needs input, and allows you to respond directly from Telegram.

Built for developers running Claude Code on remote VMs who want to stay productive while away from their terminal.

## Features

- **Push Notifications**: Receive instant Telegram notifications when Claude uses `AskUserQuestion`
- **Quick Replies**: Tap inline buttons to select from predefined options
- **Custom Responses**: Type any response directly in Telegram
- **Bidirectional**: Your replies are automatically injected into Claude's tmux session
- **Secure**: Bot only responds to your authorized Telegram account
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

## Prerequisites

- Python 3.8+
- tmux (for session management)
- jq (for JSON parsing in shell)
- A Telegram account

### Install Dependencies

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install python3 python3-pip tmux jq
```

**macOS:**
```bash
brew install python tmux jq
```

## Setup Guide

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
2. Open this URL in your browser (replace `<TOKEN>` with your bot token):
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
3. Find your chat ID in the response:
   ```json
   {"ok":true,"result":[{"message":{"chat":{"id":123456789,...}}}]}
   ```
4. **Save the chat ID** - it's the number after `"id":`

### Step 3: Clone and Configure

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/claude-notifications-webhook.git
cd claude-notifications-webhook

# Edit the configuration file
nano config.env
```

Update `config.env` with your credentials:
```bash
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklmnOPQRSTuvwxyz
TELEGRAM_CHAT_ID=123456789
```

### Step 4: Run the Installer

```bash
chmod +x install.sh
./install.sh
```

The installer will:
- Copy files to `~/.claude-telegram-notifier/`
- Install Python dependencies
- Configure Claude Code hooks in `~/.claude/settings.json`
- Set up the systemd service (Linux)

### Step 5: Start the Service

**Linux (systemd):**
```bash
# Reload systemd
systemctl --user daemon-reload

# Enable auto-start on login
systemctl --user enable claude-telegram

# Start the service
systemctl --user start claude-telegram

# Verify it's running
systemctl --user status claude-telegram
```

**macOS / Manual:**
```bash
# Run directly (for testing)
python3 ~/.claude-telegram-notifier/telegram_bot.py

# Or run in background with nohup
nohup python3 ~/.claude-telegram-notifier/telegram_bot.py > /tmp/claude-telegram.log 2>&1 &
```

### Step 6: Test the Setup

1. Start a tmux session:
   ```bash
   tmux new -s claude
   ```

2. Run Claude Code inside tmux:
   ```bash
   claude
   ```

3. Ask Claude something that triggers `AskUserQuestion`, for example:
   ```
   What programming language should I use for a new web project?
   ```

4. You should receive a Telegram notification with the question and response options!

## Usage

### Responding to Questions

**Option 1: Tap a Button**
- Questions with predefined options show inline buttons
- Tap any button to send that response to Claude

**Option 2: Type a Reply**
- Reply to the notification message with your custom answer
- Or simply send a message to the bot (it will answer the most recent question)

### Message Format

When Claude asks a question, you'll receive a message like:

```
*Claude needs input*
_Project: my-web-app_

*Q1: Which database should we use?*
  1. PostgreSQL - Robust, full-featured relational database
  2. SQLite - Lightweight, file-based database
  3. MongoDB - Document-based NoSQL database

_Reply to this message or tap a button_
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

The installer adds this to `~/.claude/settings.json`:

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
    ]
  }
}
```

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

3. **Test the Telegram bot directly:**
   ```bash
   curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
     -d "chat_id=<CHAT_ID>" \
     -d "text=Test message"
   ```

4. **Verify config.env has correct values:**
   ```bash
   cat ~/.claude-telegram-notifier/config.env
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

- Verify `TELEGRAM_CHAT_ID` matches your actual chat ID
- Re-check by visiting the getUpdates URL after sending a new message

### Service won't start

1. **Check Python dependencies:**
   ```bash
   pip3 install -r ~/.claude-telegram-notifier/requirements.txt
   ```

2. **Run manually to see errors:**
   ```bash
   python3 ~/.claude-telegram-notifier/telegram_bot.py
   ```

## File Structure

```
~/.claude-telegram-notifier/
├── telegram_bot.py      # Main daemon process
├── notify_hook.sh       # Claude Code hook script
├── config.env           # Your configuration
└── requirements.txt     # Python dependencies

~/.claude/settings.json  # Claude Code configuration (hooks)
```

## Uninstalling

```bash
# Stop and disable the service
systemctl --user stop claude-telegram
systemctl --user disable claude-telegram

# Remove files
rm -rf ~/.claude-telegram-notifier
rm ~/.config/systemd/user/claude-telegram.service

# Remove hooks from Claude settings (manual edit)
nano ~/.claude/settings.json
# Remove the PreToolUse hook for AskUserQuestion
```

## Security Considerations

- The HTTP server only binds to `127.0.0.1` (localhost)
- The Telegram bot rejects messages from unauthorized chat IDs
- Bot tokens and chat IDs are stored in `config.env` with restricted permissions
- No sensitive data is logged

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

Inspired by [Claude Code On-The-Go](https://granda.org/en/2026/01/02/claude-code-on-the-go/) which demonstrated the concept using Poke webhooks.
