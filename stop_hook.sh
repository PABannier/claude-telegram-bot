#!/bin/bash
# stop_hook.sh - Called by Claude Code Stop hook when Claude finishes responding
#
# This script:
# 1. Reads the event data from stdin (JSON from Claude Code)
# 2. Captures the current tmux location
# 3. POSTs to the local Telegram notifier daemon

set -e

# Read event data from stdin
EVENT_DATA=$(cat)

# Capture current tmux location
if [ -n "$TMUX" ]; then
    TMUX_LOCATION=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
else
    TMUX_LOCATION="unknown"
fi

# Extract the stop reason if available
STOP_REASON=$(echo "$EVENT_DATA" | jq -r '.stop_reason // "completed"' 2>/dev/null || echo "completed")

# Build payload for the daemon
PAYLOAD=$(jq -n \
    --arg loc "$TMUX_LOCATION" \
    --arg reason "$STOP_REASON" \
    --argjson event "$EVENT_DATA" \
    '{
        type: "stop",
        tmux_location: $loc,
        stop_reason: $reason,
        event_data: $event
    }')

# POST to local daemon
curl -s --connect-timeout 2 -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:8642/stop" 2>/dev/null || true

exit 0
