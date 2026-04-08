#!/usr/bin/env bash
# install.sh — install rp2040-gpio-fs Linux components on Ubuntu
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# What this script does:
#   1. Installs system dependencies (libfuse3, pkg-config, gcc)
#   2. Builds and installs the rp2040fs FUSE daemon
#   3. Installs the udev rule and systemd service
#   4. Creates the mount point and sets permissions
#   5. Adds the current user to the dialout group
#
# Firmware:
#   Flash the pre-compiled firmware/rp2040_gpio_fs.uf2 to the board
#   by holding BOOT, plugging in USB, releasing BOOT, then copying
#   the UF2 to the RPI-RP2 mass storage device that appears.

set -euo pipefail

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Must not be run as root directly
if [ "$EUID" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    error "Do not run as root. Run as your normal user: ./install.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOUNTPOINT="/mnt/rp2040"
CURRENT_USER="${SUDO_USER:-$USER}"

echo ""
echo "========================================"
echo " rp2040-gpio-fs Linux installer"
echo " User:       $CURRENT_USER"
echo " Mountpoint: $MOUNTPOINT"
echo "========================================"
echo ""

# ----------------------------------------------------------------
# Step 1 — System dependencies
# ----------------------------------------------------------------
info "Step 1: Installing system dependencies..."

sudo apt-get update -qq
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libfuse3-dev \
    gcc \
    bc

success "System dependencies installed."

# ----------------------------------------------------------------
# Step 2 — Build and install the FUSE daemon
# ----------------------------------------------------------------
info "Step 2: Building rp2040fs FUSE daemon..."

FUSE_SRC="$SCRIPT_DIR/fs_app"
if [ ! -f "$FUSE_SRC/rp2040fs.c" ]; then
    error "Cannot find $FUSE_SRC/rp2040fs.c — run this script from the linux/ directory."
fi

cd "$FUSE_SRC"
make clean
make -j$(nproc)
sudo cp rp2040fs /usr/local/bin/rp2040fs
sudo chmod +x /usr/local/bin/rp2040fs
success "rp2040fs installed to /usr/local/bin/rp2040fs."

cd "$SCRIPT_DIR"

# ----------------------------------------------------------------
# Step 3 — Install udev rule
# ----------------------------------------------------------------
info "Step 3: Installing udev rule..."

RULES_SRC="$SCRIPT_DIR/config/99-rp2040-gpio-fs.rules"
if [ ! -f "$RULES_SRC" ]; then
    error "Cannot find $RULES_SRC"
fi

# Substitute the actual username into the udev rule
sed "s/YOUR_USERNAME/$CURRENT_USER/g" "$RULES_SRC" \
    | sudo tee /etc/udev/rules.d/99-rp2040-gpio-fs.rules > /dev/null

sudo udevadm control --reload-rules
sudo udevadm trigger
success "udev rule installed and reloaded."

# ----------------------------------------------------------------
# Step 4 — Install systemd service
# ----------------------------------------------------------------
info "Step 4: Installing systemd service..."

SERVICE_SRC="$SCRIPT_DIR/config/rp2040fs@.service"
if [ ! -f "$SERVICE_SRC" ]; then
    error "Cannot find $SERVICE_SRC"
fi

sudo cp "$SERVICE_SRC" /etc/systemd/system/rp2040fs@.service
sudo systemctl daemon-reload
success "systemd service installed (rp2040fs@.service)."

# ----------------------------------------------------------------
# Step 5 — Create mount point
# ----------------------------------------------------------------
info "Step 5: Creating mount point at $MOUNTPOINT..."

sudo mkdir -p "$MOUNTPOINT"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$MOUNTPOINT"
success "Mount point created and owned by $CURRENT_USER."

# ----------------------------------------------------------------
# Step 6 — Add user to dialout group
# ----------------------------------------------------------------
info "Step 6: Adding $CURRENT_USER to dialout group..."

if groups "$CURRENT_USER" | grep -q dialout; then
    success "$CURRENT_USER is already in the dialout group."
else
    sudo usermod -a -G dialout "$CURRENT_USER"
    warn "$CURRENT_USER added to dialout — log out and back in for this to take effect."
    NEEDS_LOGOUT=1
fi

# ----------------------------------------------------------------
# Step 7 — Verify installation
# ----------------------------------------------------------------
info "Step 7: Verifying installation..."

VERIFY_FAIL=0

check_file() {
    if [ -f "$1" ]; then
        success "Found: $1"
    else
        warn "Missing: $1"
        VERIFY_FAIL=$((VERIFY_FAIL+1))
    fi
}

check_file /usr/local/bin/rp2040fs
check_file /etc/udev/rules.d/99-rp2040-gpio-fs.rules
check_file /etc/systemd/system/rp2040fs@.service

if [ "$VERIFY_FAIL" -eq 0 ]; then
    success "All files verified."
else
    warn "$VERIFY_FAIL file(s) missing — review output above."
fi

# ----------------------------------------------------------------
# Done
# ----------------------------------------------------------------
echo ""
echo "========================================"
echo -e " ${GREEN}Installation complete!${NC}"
echo "========================================"
echo ""
echo " Next steps:"
echo ""
echo " 1. Flash the firmware to the RP2040 Zero:"
echo "    - Hold BOOT, plug in USB, release BOOT"
echo "    - Copy the UF2 to the board:"
echo "      cp $REPO_ROOT/firmware/rp2040_gpio_fs.uf2 /media/\$USER/RPI-RP2/"
echo ""
echo " 2. Plug in the board — filesystem mounts automatically."
echo "    Check with: systemctl status rp2040fs@$CURRENT_USER"
echo ""
echo " 3. Use it:"
echo "    ls $MOUNTPOINT/gpio/"
echo "    echo out > $MOUNTPOINT/gpio/gpio0/mode"
echo "    echo 1   > $MOUNTPOINT/gpio/gpio0/value"
echo ""

if [ "${NEEDS_LOGOUT:-0}" = "1" ]; then
    echo -e " ${YELLOW}IMPORTANT:${NC} Log out and back in for dialout group to take effect."
    echo ""
fi
