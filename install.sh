#!/bin/bash
# install.sh - Claude Telegram Notifier Installer
#
# One-liner installation:
#   curl -fsSL https://raw.githubusercontent.com/PABannier/claude-telegram-bot/main/install.sh | bash
#
# This script:
# 1. Downloads all necessary files from GitHub
# 2. Prompts for Telegram credentials interactively
# 3. Encrypts and securely stores credentials
# 4. Sets up systemd service and Claude Code hooks

set -e

# Configuration
REPO_URL="https://raw.githubusercontent.com/PABannier/claude-telegram-bot/main"
INSTALL_DIR="$HOME/.claude-telegram-notifier"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
ENCRYPTION_KEY_FILE="$INSTALL_DIR/.encryption_key"
ENCRYPTED_CONFIG_FILE="$INSTALL_DIR/.config.enc"
CONFIG_FILE="$INSTALL_DIR/config.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         Claude Code Telegram Notifier Installer          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Check for required commands
check_dependencies() {
    local missing=()

    for cmd in python3 pip3 curl openssl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing[*]}"
        echo
        echo "Install them with:"
        if [ "$(uname)" = "Linux" ]; then
            echo "  sudo apt update && sudo apt install -y python3 python3-pip curl jq"
        else
            echo "  brew install python curl jq openssl"
        fi
        exit 1
    fi
}

# Generate a secure random encryption key
generate_encryption_key() {
    openssl rand -base64 32
}

# Encrypt a value using the encryption key
encrypt_value() {
    local value="$1"
    local key="$2"
    echo -n "$value" | openssl enc -aes-256-cbc -pbkdf2 -base64 -pass "pass:$key" 2>/dev/null
}

# Decrypt a value using the encryption key
decrypt_value() {
    local encrypted="$1"
    local key="$2"
    echo -n "$encrypted" | openssl enc -aes-256-cbc -pbkdf2 -base64 -d -pass "pass:$key" 2>/dev/null
}

# Prompt for Telegram bot token
prompt_bot_token() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 1: Telegram Bot Token${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo "To get your bot token:"
    echo "  1. Open Telegram and search for @BotFather"
    echo "  2. Send /newbot and follow the prompts"
    echo "  3. Copy the token (looks like: 123456789:ABCdefGHI...)"
    echo

    while true; do
        read -rp "Enter your Telegram Bot Token: " BOT_TOKEN < /dev/tty

        # Basic validation
        if [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            # Verify token with Telegram API
            print_info "Verifying token with Telegram API..."
            local response
            response=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)

            if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
                local bot_name
                bot_name=$(echo "$response" | jq -r '.result.username')
                print_step "Token verified! Bot: @$bot_name"
                break
            else
                print_error "Invalid token. Please check and try again."
            fi
        else
            print_error "Token format looks incorrect. It should be like: 123456789:ABCdefGHI..."
        fi
    done
}

# Prompt for Chat ID
prompt_chat_id() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 2: Your Telegram Chat ID${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo "To get your Chat ID:"
    echo "  1. Start a chat with your bot (send any message)"
    echo "  2. The installer will try to detect it automatically"
    echo

    print_info "Checking for messages sent to your bot..."

    # Try to auto-detect chat ID from recent messages
    local updates
    updates=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null)

    local detected_chat_id
    detected_chat_id=$(echo "$updates" | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null)

    if [ -n "$detected_chat_id" ]; then
        local chat_name
        chat_name=$(echo "$updates" | jq -r '.result[-1].message.chat.first_name // .result[-1].message.chat.username // "Unknown"' 2>/dev/null)
        echo
        print_step "Detected Chat ID: $detected_chat_id (User: $chat_name)"
        read -rp "Use this Chat ID? [Y/n]: " use_detected < /dev/tty

        if [[ -z "$use_detected" || "$use_detected" =~ ^[Yy] ]]; then
            CHAT_ID="$detected_chat_id"
            return
        fi
    else
        print_warning "No messages found. Please send a message to your bot first."
        echo
        echo "After sending a message, you can find your Chat ID at:"
        echo "  https://api.telegram.org/bot${BOT_TOKEN}/getUpdates"
        echo
    fi

    while true; do
        read -rp "Enter your Telegram Chat ID: " CHAT_ID < /dev/tty

        if [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            # Verify by sending a test message
            print_info "Sending test message to verify Chat ID..."
            local response
            response=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" \
                -d "text=✅ Claude Telegram Notifier connected successfully!" 2>/dev/null)

            if echo "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
                print_step "Chat ID verified! Check your Telegram for a test message."
                break
            else
                local error_msg
                error_msg=$(echo "$response" | jq -r '.description // "Unknown error"')
                print_error "Failed to send message: $error_msg"
            fi
        else
            print_error "Chat ID should be a number (can be negative for groups)"
        fi
    done
}

# Download files from GitHub
download_files() {
    echo
    print_info "Downloading files from GitHub..."

    mkdir -p "$INSTALL_DIR"

    # Download main Python daemon
    curl -fsSL "${REPO_URL}/telegram_bot.py" -o "$INSTALL_DIR/telegram_bot.py" || {
        print_error "Failed to download telegram_bot.py"
        exit 1
    }

    # Download hook script
    curl -fsSL "${REPO_URL}/notify_hook.sh" -o "$INSTALL_DIR/notify_hook.sh" || {
        print_error "Failed to download notify_hook.sh"
        exit 1
    }
    chmod +x "$INSTALL_DIR/notify_hook.sh"

    # Download requirements
    curl -fsSL "${REPO_URL}/requirements.txt" -o "$INSTALL_DIR/requirements.txt" || {
        print_error "Failed to download requirements.txt"
        exit 1
    }

    print_step "Downloaded all files to $INSTALL_DIR"
}

# Store credentials securely
store_credentials() {
    echo
    print_info "Encrypting and storing credentials..."

    # Generate encryption key
    local encryption_key
    encryption_key=$(generate_encryption_key)

    # Store encryption key with restrictive permissions
    echo "$encryption_key" > "$ENCRYPTION_KEY_FILE"
    chmod 600 "$ENCRYPTION_KEY_FILE"

    # Encrypt credentials
    local encrypted_token
    local encrypted_chat_id
    encrypted_token=$(encrypt_value "$BOT_TOKEN" "$encryption_key")
    encrypted_chat_id=$(encrypt_value "$CHAT_ID" "$encryption_key")

    # Store encrypted config
    cat > "$ENCRYPTED_CONFIG_FILE" << EOF
ENCRYPTED_TELEGRAM_BOT_TOKEN=$encrypted_token
ENCRYPTED_TELEGRAM_CHAT_ID=$encrypted_chat_id
HTTP_PORT=8642
HTTP_HOST=127.0.0.1
QUESTION_TIMEOUT_SECONDS=3600
EOF
    chmod 600 "$ENCRYPTED_CONFIG_FILE"

    # Create decryption wrapper script
    cat > "$INSTALL_DIR/decrypt_config.sh" << 'DECRYPT_SCRIPT'
#!/bin/bash
# Decrypt configuration and export as environment variables

INSTALL_DIR="$HOME/.claude-telegram-notifier"
ENCRYPTION_KEY_FILE="$INSTALL_DIR/.encryption_key"
ENCRYPTED_CONFIG_FILE="$INSTALL_DIR/.config.enc"

if [ ! -f "$ENCRYPTION_KEY_FILE" ] || [ ! -f "$ENCRYPTED_CONFIG_FILE" ]; then
    echo "Error: Encrypted configuration not found" >&2
    exit 1
fi

KEY=$(cat "$ENCRYPTION_KEY_FILE")

# Source the encrypted config to get values
source "$ENCRYPTED_CONFIG_FILE"

# Decrypt and export
export TELEGRAM_BOT_TOKEN=$(echo -n "$ENCRYPTED_TELEGRAM_BOT_TOKEN" | openssl enc -aes-256-cbc -pbkdf2 -base64 -d -pass "pass:$KEY" 2>/dev/null)
export TELEGRAM_CHAT_ID=$(echo -n "$ENCRYPTED_TELEGRAM_CHAT_ID" | openssl enc -aes-256-cbc -pbkdf2 -base64 -d -pass "pass:$KEY" 2>/dev/null)
export HTTP_PORT
export HTTP_HOST
export QUESTION_TIMEOUT_SECONDS

# Execute the command passed as arguments
exec "$@"
DECRYPT_SCRIPT
    chmod 700 "$INSTALL_DIR/decrypt_config.sh"

    # Also create a plain config.env for the Python script (it reads from env vars)
    # The systemd service will use the decrypt wrapper
    cat > "$CONFIG_FILE" << EOF
# This file is auto-generated. Credentials are stored encrypted.
# The daemon loads decrypted values at runtime via decrypt_config.sh
HTTP_PORT=8642
HTTP_HOST=127.0.0.1
QUESTION_TIMEOUT_SECONDS=3600
EOF
    chmod 600 "$CONFIG_FILE"

    print_step "Credentials encrypted and stored securely"
}

# Install Python dependencies
install_python_deps() {
    echo
    print_info "Installing Python dependencies..."
    pip3 install -q pyTelegramBotAPI python-dotenv 2>/dev/null || {
        print_warning "pip3 install failed, trying with --user flag..."
        pip3 install --user -q pyTelegramBotAPI python-dotenv
    }
    print_step "Python dependencies installed"
}

# Configure Claude Code hooks
configure_claude_hooks() {
    echo
    print_info "Configuring Claude Code hooks..."

    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

    if [ -f "$CLAUDE_SETTINGS" ]; then
        # Backup existing settings
        cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup.$(date +%s)"

        # Check if jq can parse the file
        if ! jq empty "$CLAUDE_SETTINGS" 2>/dev/null; then
            print_warning "Existing settings.json is invalid, creating new one"
            create_new_settings
            return
        fi

        # Check if hooks section exists
        if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
            # Check if our hook is already there
            if jq -e '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion")' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
                print_step "AskUserQuestion hook already configured"
            else
                # Add our hook to existing PreToolUse array
                jq '.hooks.PreToolUse += [{
                    "matcher": "AskUserQuestion",
                    "hooks": [{
                        "type": "command",
                        "command": "'"$INSTALL_DIR"'/notify_hook.sh"
                    }]
                }]' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
                print_step "Added AskUserQuestion hook to existing configuration"
            fi
        else
            # Add hooks section to existing config
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
            print_step "Added hooks configuration"
        fi
    else
        create_new_settings
    fi
}

create_new_settings() {
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
    print_step "Created new Claude settings.json"
}

# Setup systemd service
setup_systemd_service() {
    echo
    print_info "Setting up systemd service..."

    if [ "$(uname)" != "Linux" ]; then
        print_warning "Non-Linux system detected. Skipping systemd setup."
        echo
        echo "To run the daemon manually:"
        echo "  $INSTALL_DIR/decrypt_config.sh python3 $INSTALL_DIR/telegram_bot.py"
        return
    fi

    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/claude-telegram.service" << EOF
[Unit]
Description=Claude Code Telegram Notifier
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/decrypt_config.sh /usr/bin/python3 $INSTALL_DIR/telegram_bot.py
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=10
Environment=HOME=$HOME

[Install]
WantedBy=default.target
EOF

    print_step "Created systemd service"

    # Reload and enable
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable claude-telegram 2>/dev/null || true

    print_step "Enabled systemd service"
}

# Start the service
start_service() {
    echo
    read -rp "Start the notification service now? [Y/n]: " start_now < /dev/tty

    if [[ -z "$start_now" || "$start_now" =~ ^[Yy] ]]; then
        if [ "$(uname)" = "Linux" ]; then
            systemctl --user start claude-telegram 2>/dev/null && {
                print_step "Service started successfully"
                sleep 2
                if systemctl --user is-active claude-telegram > /dev/null 2>&1; then
                    print_step "Service is running"
                else
                    print_warning "Service may have failed to start. Check logs with:"
                    echo "  journalctl --user -u claude-telegram -f"
                fi
            } || {
                print_warning "Failed to start service. Try manually:"
                echo "  systemctl --user start claude-telegram"
            }
        else
            print_info "Starting daemon in background..."
            nohup "$INSTALL_DIR/decrypt_config.sh" python3 "$INSTALL_DIR/telegram_bot.py" > /tmp/claude-telegram.log 2>&1 &
            print_step "Daemon started (PID: $!)"
        fi
    fi
}

# Print final instructions
print_final_instructions() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Installation Complete!                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Your credentials are encrypted and stored in:"
    echo "  $ENCRYPTED_CONFIG_FILE"
    echo
    echo -e "${BLUE}Service Management:${NC}"
    if [ "$(uname)" = "Linux" ]; then
        echo "  Start:   systemctl --user start claude-telegram"
        echo "  Stop:    systemctl --user stop claude-telegram"
        echo "  Status:  systemctl --user status claude-telegram"
        echo "  Logs:    journalctl --user -u claude-telegram -f"
    else
        echo "  Start:   $INSTALL_DIR/decrypt_config.sh python3 $INSTALL_DIR/telegram_bot.py"
    fi
    echo
    echo -e "${BLUE}Testing:${NC}"
    echo "  1. Start Claude Code inside a tmux session:"
    echo "     tmux new -s claude && claude"
    echo
    echo "  2. Ask Claude something that triggers AskUserQuestion"
    echo "     Example: 'What database should I use for my project?'"
    echo
    echo "  3. You should receive a Telegram notification!"
    echo
    echo -e "${YELLOW}Note:${NC} Always run Claude Code inside tmux for response injection to work."
    echo
}

# Uninstall function (can be called with --uninstall flag)
uninstall() {
    echo "Uninstalling Claude Telegram Notifier..."

    # Stop service
    if [ "$(uname)" = "Linux" ]; then
        systemctl --user stop claude-telegram 2>/dev/null || true
        systemctl --user disable claude-telegram 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/claude-telegram.service"
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    # Remove installation directory
    rm -rf "$INSTALL_DIR"

    # Remove hook from Claude settings (keep other settings)
    if [ -f "$CLAUDE_SETTINGS" ] && command -v jq &> /dev/null; then
        jq 'del(.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion"))' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" 2>/dev/null && \
        mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
    fi

    print_step "Uninstallation complete"
}

# Main installation flow
main() {
    # Handle flags
    case "${1:-}" in
        --uninstall)
            uninstall
            exit 0
            ;;
        --help|-h)
            echo "Claude Telegram Notifier Installer"
            echo
            echo "Usage:"
            echo "  curl -fsSL <repo>/install.sh | bash     # Install"
            echo "  ./install.sh --uninstall                # Uninstall"
            echo
            exit 0
            ;;
    esac

    print_header

    # Check if already installed
    if [ -f "$ENCRYPTED_CONFIG_FILE" ]; then
        print_warning "Existing installation detected at $INSTALL_DIR"
        read -rp "Reinstall? This will overwrite existing configuration. [y/N]: " reinstall < /dev/tty
        if [[ ! "$reinstall" =~ ^[Yy] ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    fi

    check_dependencies
    download_files
    prompt_bot_token
    prompt_chat_id
    store_credentials
    install_python_deps
    configure_claude_hooks
    setup_systemd_service
    start_service
    print_final_instructions
}

# Run main
main "$@"
