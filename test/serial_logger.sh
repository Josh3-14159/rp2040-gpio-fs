#!/usr/bin/env bash
# serial_logger.sh — log all serial traffic on the rp2040 GPIO filesystem
#
# Usage:
#   ./serial_logger.sh                        # log to stdout
#   ./serial_logger.sh -o logfile.txt         # log to file
#   ./serial_logger.sh -o logfile.txt -t      # log to file and stdout
#   ./serial_logger.sh -s rp2040fs@srt        # specify service

set -euo pipefail

SERVICE="rp2040fs@${SUDO_USER:-$USER}"
OUTFILE=""
TEE_OUTPUT=0
RESTARTED_VERBOSE=0
SERVICE_FILE="/etc/systemd/system/rp2040fs@.service"

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

cleanup() {
    echo ""
    if [ "$RESTARTED_VERBOSE" -eq 1 ]; then
        echo "Reverting service file and restarting in normal mode..."
        sudo sed -i 's/ --verbose//' "$SERVICE_FILE"
        sudo systemctl daemon-reload
        sudo systemctl restart "$SERVICE" 2>/dev/null || true
        echo "Service restored to normal mode."
    fi
    echo "Logger stopped."
}
trap cleanup EXIT INT TERM

if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "Error: $SERVICE is not running."
    echo "Plug in the board and wait for the service to start, then retry."
    exit 1
fi

is_verbose() {
    grep -q -- "--verbose" "$SERVICE_FILE" 2>/dev/null
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
    echo "   y — temporarily add --verbose to the service file and restart"
    echo "       (the service file will be reverted when the logger exits)"
    echo "   n — exit without changes"
    echo ""
    read -rp " Enable verbose mode? [y/N] " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS])
            echo ""
            echo "Adding --verbose to $SERVICE_FILE..."
            sudo sed -i 's|ExecStart=/usr/local/bin/rp2040fs|ExecStart=/usr/local/bin/rp2040fs --verbose|' \
                "$SERVICE_FILE"
            sudo systemctl daemon-reload
            echo "Restarting $SERVICE in verbose mode..."
            sudo systemctl restart "$SERVICE"
            RESTARTED_VERBOSE=1
            sleep 2
            if ! systemctl is-active --quiet "$SERVICE"; then
                echo "Error: service failed to restart."
                echo "Check: sudo journalctl -u $SERVICE"
                exit 1
            fi
            echo "Service running in verbose mode."
            echo ""
            ;;
        *)
            echo "Exiting."
            exit 0
            ;;
    esac
fi

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

if [ -n "$OUTFILE" ]; then
    if [ "$TEE_OUTPUT" -eq 1 ]; then
        sudo journalctl -fu "$SERVICE" | format_line | tee "$OUTFILE"
    else
        echo "Logging to $OUTFILE (silent -- use -t to also print to screen)"
        sudo journalctl -fu "$SERVICE" | format_line >> "$OUTFILE"
    fi
else
    sudo journalctl -fu "$SERVICE" | format_line
fi
