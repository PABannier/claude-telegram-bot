#!/bin/bash
# install.sh - Install Claude Telegram Notifier
#
# This script:
# 1. Copies files to ~/.claude-telegram-notifier
# 2. Installs Python dependencies
# 3. Sets up systemd service (Linux) or provides manual instructions
# 4. Updates Claude Code settings.json with the hook configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.claude-telegram-notifier"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "==================================="
echo "Claude Telegram Notifier Installer"
echo "==================================="
echo

# Create installation directory
echo "[1/5] Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Copy files
echo "[2/5] Copying files..."
cp "$SCRIPT_DIR/telegram_bot.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/notify_hook.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"

# Make hook script executable
chmod +x "$INSTALL_DIR/notify_hook.sh"

# Copy config if it doesn't exist (don't overwrite existing config)
if [ ! -f "$INSTALL_DIR/config.env" ]; then
    cp "$SCRIPT_DIR/config.env" "$INSTALL_DIR/"
    echo "    Created config.env template"
else
    echo "    Keeping existing config.env"
fi

# Install Python dependencies
echo "[3/5] Installing Python dependencies..."
pip3 install -q -r "$INSTALL_DIR/requirements.txt"

# Check for jq (required by hook script)
if ! command -v jq &> /dev/null; then
    echo "    WARNING: 'jq' is not installed. Install it with:"
    echo "      Ubuntu/Debian: sudo apt install jq"
    echo "      macOS: brew install jq"
fi

# Update Claude settings
echo "[4/5] Updating Claude Code settings..."
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

if [ -f "$CLAUDE_SETTINGS" ]; then
    # Backup existing settings
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup"
    echo "    Backed up existing settings to settings.json.backup"

    # Check if hooks already exist
    if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
        # Check if our hook is already there
        if jq -e '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion")' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
            echo "    AskUserQuestion hook already configured"
        else
            # Add our hook to existing PreToolUse array
            jq '.hooks.PreToolUse += [{
                "matcher": "AskUserQuestion",
                "hooks": [{
                    "type": "command",
                    "command": "'"$INSTALL_DIR"'/notify_hook.sh"
                }]
            }]' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
            echo "    Added AskUserQuestion hook"
        fi
    else
        # Add hooks section
        jq '. + {
            "hooks": {
                "PreToolUse": [{
                    "matcher": "AskUserQuestion",
                    "hooks": [{
                        "type": "command",
                        "command": "'"$INSTALL_DIR"'/notify_hook.sh"
                    }]
                }]
            }
        }' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
        echo "    Added hooks configuration"
    fi
else
    # Create new settings file
    cat > "$CLAUDE_SETTINGS" << EOF
{
    "hooks": {
        "PreToolUse": [{
            "matcher": "AskUserQuestion",
            "hooks": [{
                "type": "command",
                "command": "$INSTALL_DIR/notify_hook.sh"
            }]
        }]
    }
}
EOF
    echo "    Created new settings.json"
fi

# Setup systemd service (Linux only)
echo "[5/5] Setting up daemon service..."
if [ "$(uname)" = "Linux" ]; then
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/claude-telegram.service" << EOF
[Unit]
Description=Claude Code Telegram Notifier
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/telegram_bot.py
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config.env
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    echo "    Created systemd service"
    echo
    echo "To enable and start the service:"
    echo "    systemctl --user daemon-reload"
    echo "    systemctl --user enable claude-telegram"
    echo "    systemctl --user start claude-telegram"
    echo
    echo "To view logs:"
    echo "    journalctl --user -u claude-telegram -f"
else
    echo "    Non-Linux system detected. Manual daemon setup required."
    echo
    echo "To run the daemon manually:"
    echo "    python3 $INSTALL_DIR/telegram_bot.py"
    echo
    echo "For background execution, consider using screen/tmux or creating a launchd plist (macOS)"
fi

echo
echo "==================================="
echo "Installation complete!"
echo "==================================="
echo
echo "NEXT STEPS:"
echo "1. Edit $INSTALL_DIR/config.env with your Telegram credentials"
echo "   - TELEGRAM_BOT_TOKEN: Get from @BotFather"
echo "   - TELEGRAM_CHAT_ID: Get from API after messaging your bot"
echo
echo "2. Start the daemon (see instructions above)"
echo
echo "3. Test by running Claude Code in tmux and triggering AskUserQuestion"
echo
