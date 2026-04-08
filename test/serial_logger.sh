#!/usr/bin/env bash
# serial_logger.sh — log all serial traffic on the rp2040 GPIO filesystem
#
# Usage:
#   ./serial_logger.sh                        # log to stdout
#   ./serial_logger.sh -o logfile.txt         # log to file
#   ./serial_logger.sh -o logfile.txt -t      # log to file and stdout
#   ./serial_logger.sh -d /dev/ttyACM0        # specify device
#
# Requires rp2040fs to be running with --verbose flag.
# Reads from the systemd journal filtering for CMD: lines.

set -euo pipefail

# ----------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------
SERVICE="rp2040fs@${SUDO_USER:-$USER}"
OUTFILE=""
TEE_OUTPUT=0

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
# Check the service is running with --verbose
# ----------------------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "Error: $SERVICE is not running."
    echo "Start it with --verbose to enable serial logging:"
    echo "  sudo systemctl stop $SERVICE"
    echo "  /usr/local/bin/rp2040fs /mnt/rp2040 --device /dev/rp2040_gpio_fs --verbose -f -s &"
    exit 1
fi

# Check verbose is enabled by looking for a recent CMD entry
if ! sudo journalctl -u "$SERVICE" -n 50 --no-pager 2>/dev/null | grep -q "CMD:"; then
    echo "Warning: no CMD: entries found in journal."
    echo "The service may not be running with --verbose."
    echo ""
    echo "To enable verbose logging permanently:"
    echo "  sudo systemctl edit rp2040fs@.service"
    echo "  Add under [Service]:"
    echo "    ExecStart="
    echo "    ExecStart=/usr/local/bin/rp2040fs /mnt/rp2040 --device /dev/rp2040_gpio_fs --verbose"
    echo "  Then: sudo systemctl restart $SERVICE"
    echo ""
    read -rp "Continue anyway? [y/N] " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS]) ;;
        *) exit 0 ;;
    esac
fi

# ----------------------------------------------------------------
# Build the log pipeline
# ----------------------------------------------------------------
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

echo "========================================"
echo " RP2040 Serial Logger"
echo " Service:  $SERVICE"
echo " Started:  $(date '+%Y-%m-%d %H:%M:%S')"
[ -n "$OUTFILE" ] && echo " Log file: $OUTFILE"
echo " Press Ctrl+C to stop"
echo "========================================"
echo ""

# Format: strip journalctl metadata, keep only CMD: lines with timestamp
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

# Run the journal follow pipeline
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
