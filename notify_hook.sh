#!/bin/bash
# notify_hook.sh - Called by Claude Code PreToolUse hook when AskUserQuestion is invoked
#
# This script:
# 1. Reads the event data from stdin (JSON from Claude Code)
# 2. Captures the current tmux location
# 3. Enriches the event data with tmux location
# 4. POSTs to the local Telegram notifier daemon

set -e

# Read event data from stdin
EVENT_DATA=$(cat)

# Capture current tmux location
if [ -n "$TMUX" ]; then
    TMUX_LOCATION=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
else
    # Not in tmux - response injection won't work
    echo "Warning: Not running in tmux. Response injection will fail." >&2
    TMUX_LOCATION="unknown"
fi

# Enrich event data with tmux location
ENRICHED_DATA=$(echo "$EVENT_DATA" | jq --arg loc "$TMUX_LOCATION" '. + {tmux_location: $loc}')

# POST to local daemon
# Use --connect-timeout to avoid blocking Claude if daemon is down
RESPONSE=$(curl -s --connect-timeout 2 -X POST \
    -H "Content-Type: application/json" \
    -d "$ENRICHED_DATA" \
    "http://127.0.0.1:8642/notify" 2>/dev/null) || {
    echo "Warning: Telegram notifier daemon not responding" >&2
    exit 0  # Don't block Claude
}

# Log response for debugging (optional)
# echo "Notifier response: $RESPONSE" >&2

# Exit 0 to allow the tool to proceed
# The actual response will come from Telegram -> tmux injection
exit 0
