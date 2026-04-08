#!/usr/bin/env bash
# serial_logger.sh — log all serial traffic on the rp2040 GPIO filesystem
#
# Usage:
#   ./serial_logger.sh                        # log to stdout
#   ./serial_logger.sh -o logfile.txt         # log to file
#   ./serial_logger.sh -o logfile.txt -t      # log to file and stdout
#   ./serial_logger.sh -s rp2040fs@srt        # specify service

set -euo pipefail

# ----------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------
SERVICE="rp2040fs@${SUDO_USER:-$USER}"
OUTFILE=""
TEE_OUTPUT=0
RESTARTED_VERBOSE=0

# ----------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------
usage() {
    echo "Usage: $0 [-o <logfile>] [-t] [-s <service>]"
    echo "  -o  Write log to file"
    echo "  -t  Tee output to both file and stdout (requires -o)"
    echo "  -s  Systemd service name (default: rp2040fs@$USER)"
    exit 1
}

while getopts "o:ts:h" opt; do
    case $opt in
        o) OUTFILE="$OPTARG" ;;
        t) TEE_OUTPUT=1 ;;
        s) SERVICE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ----------------------------------------------------------------
# Cleanup — restore service to normal mode on exit
# ----------------------------------------------------------------
cleanup() {
    echo ""
    if [ "$RESTARTED_VERBOSE" -eq 1 ]; then
        echo "Restoring service to normal (non-verbose) mode..."
        sudo systemctl stop "$SERVICE" 2>/dev/null || true
        sudo systemctl start "$SERVICE" 2>/dev/null || true
        echo "Service restarted in normal mode."
    fi
    echo "Logger stopped."
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------
# Check the service is running
# ----------------------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "Error: $SERVICE is not running."
    echo "Plug in the board and wait for the service to start, then retry."
    exit 1
fi

# ----------------------------------------------------------------
# Check if verbose mode is active
# ----------------------------------------------------------------
is_verbose() {
    sudo journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null | grep -q "CMD:"
}

if ! is_verbose; then
    echo "========================================"
    echo " RP2040 Serial Logger"
    echo "========================================"
    echo ""
    echo " The service is running but not in verbose mode."
    echo " Verbose mode is required to log serial traffic."
    echo ""
    echo " Options:"
    echo "   y — restart the service in verbose mode now"
    echo "       (will be restored to normal when logger exits)"
    echo "   n — exit without changes"
    echo ""
    read -rp " Restart in verbose mode? [y/N] " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS])
            echo ""
            echo "Restarting $SERVICE in verbose mode..."
            sudo systemctl stop "$SERVICE"
            # Start with verbose flag directly, bypassing systemd
            # so we can restore it cleanly on exit
            sudo /usr/local/bin/rp2040fs /mnt/rp2040 \
                --device /dev/rp2040_gpio_fs \
                --verbose -f -s \
                > /tmp/rp2040fs-verbose.log 2>&1 &
            RP2040_PID=$!
            RESTARTED_VERBOSE=1
            # Wait for it to come up
            sleep 2
            if ! kill -0 $RP2040_PID 2>/dev/null; then
                echo "Error: failed to start service in verbose mode."
                echo "Check /tmp/rp2040fs-verbose.log for details."
                exit 1
            fi
            echo "Service running in verbose mode (PID $RP2040_PID)."
            echo ""
            ;;
        *)
            echo "Exiting."
            exit 0
            ;;
    esac
fi

# ----------------------------------------------------------------
# Build the log pipeline
# ----------------------------------------------------------------
echo "========================================"
echo " RP2040 Serial Logger"
echo " Service:  $SERVICE"
echo " Started:  $(date '+%Y-%m-%d %H:%M:%S')"
[ -n "$OUTFILE" ] && echo " Log file: $OUTFILE"
echo " Press Ctrl+C to stop"
echo "========================================"
echo ""

format_line() {
    while IFS= read -r line; do
        if echo "$line" | grep -q "CMD:"; then
            TS=$(date '+%H:%M:%S.%3N')
            CMD=$(echo "$line" | sed 's/.*CMD: //')
            TX=$(echo "$CMD" | cut -d'-' -f1 | xargs)
            RX=$(echo "$CMD" | cut -d'>' -f2 | xargs)
            echo "$TS  TX: $TX"
            echo "$TS  RX: $RX"
            echo ""
        fi
    done
}

if [ "$RESTARTED_VERBOSE" -eq 1 ]; then
    # Service was started directly — tail its log file
    if [ -n "$OUTFILE" ]; then
        if [ "$TEE_OUTPUT" -eq 1 ]; then
            tail -f /tmp/rp2040fs-verbose.log | format_line | tee "$OUTFILE"
        else
            echo "Logging to $OUTFILE (silent — use -t to also print to screen)"
            tail -f /tmp/rp2040fs-verbose.log | format_line >> "$OUTFILE"
        fi
    else
        tail -f /tmp/rp2040fs-verbose.log | format_line
    fi
else
    # Service was already verbose — read from journal
    if [ -n "$OUTFILE" ]; then
        if [ "$TEE_OUTPUT" -eq 1 ]; then
            sudo journalctl -fu "$SERVICE" | format_line | tee "$OUTFILE"
        else
            echo "Logging to $OUTFILE (silent — use -t to also print to screen)"
            sudo journalctl -fu "$SERVICE" | format_line >> "$OUTFILE"
        fi
    else
        sudo journalctl -fu "$SERVICE" | format_line
    fi
fi
