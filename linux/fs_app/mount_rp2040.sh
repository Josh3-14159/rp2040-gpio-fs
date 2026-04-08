#!/usr/bin/env bash
# mount_rp2040.sh — mount or unmount the RP2040 GPIO filesystem
#
# Usage:
#   ./mount_rp2040.sh [mount]   — mount at /mnt/rp2040
#   ./mount_rp2040.sh unmount   — unmount

set -euo pipefail

MOUNTPOINT="/mnt/rp2040"
DAEMON="$(dirname "$0")/rp2040fs"
DEVICE="${RP2040_DEVICE:-/dev/rp2040_gpio_fs}"   # udev symlink, fallback below

# Fallback: find first matching ttyACM device if symlink absent
if [ ! -e "$DEVICE" ]; then
    DEVICE=$(ls /dev/ttyACM* 2>/dev/null | head -n1 || true)
fi

if [ -z "$DEVICE" ] || [ ! -e "$DEVICE" ]; then
    echo "Error: RP2040 device not found. Is it plugged in?" >&2
    exit 1
fi

ACTION="${1:-mount}"

case "$ACTION" in
    mount)
        if mountpoint -q "$MOUNTPOINT"; then
            echo "$MOUNTPOINT is already mounted."
            exit 0
        fi
        sudo mkdir -p "$MOUNTPOINT"
        echo "Mounting RP2040 GPIO FS at $MOUNTPOINT using $DEVICE ..."
        "$DAEMON" "$MOUNTPOINT" --device "$DEVICE"
        echo "Mounted."
        ;;
    unmount|umount)
        if ! mountpoint -q "$MOUNTPOINT"; then
            echo "$MOUNTPOINT is not mounted."
            exit 0
        fi
        echo "Unmounting $MOUNTPOINT ..."
        fusermount3 -u "$MOUNTPOINT"
        echo "Unmounted."
        ;;
    *)
        echo "Usage: $0 [mount|unmount]"
        exit 1
        ;;
esac
