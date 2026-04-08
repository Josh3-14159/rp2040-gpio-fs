# rp2040-gpio-fs

Exposes the GPIO, ADC, and PWM peripherals of a Waveshare RP2040 Zero as a
FUSE filesystem on Linux. Interact with hardware by reading and writing files —
no drivers, no libraries, no root required after initial setup.

```bash
# Set a pin high
echo "out" > /mnt/rp2040/gpio/gpio15/mode
echo "1"   > /mnt/rp2040/gpio/gpio15/value

# Read a pin with pull-up
echo "in"  > /mnt/rp2040/gpio/gpio4/mode
echo "up"  > /mnt/rp2040/gpio/gpio4/pull
cat /mnt/rp2040/gpio/gpio4/value

# Read ADC voltage
echo "adc" > /mnt/rp2040/gpio/gpio26/mode
cat /mnt/rp2040/gpio/gpio26/value
# 2048 1.6504

# 1kHz PWM at 50% duty
echo "pwm"   > /mnt/rp2040/gpio/gpio0/mode
echo "1000"  > /mnt/rp2040/gpio/gpio0/pwm_freq
echo "32768" > /mnt/rp2040/gpio/gpio0/pwm_duty
```

---

## Hardware

**Waveshare RP2040 Zero** — any revision.

### Exposed pins

| Pins | Modes available |
|------|----------------|
| GP0-GP22 | in, out, pwm |
| GP26-GP29 | in, out, pwm, adc |

GP23, GP24, GP25 (onboard WS2812 LED) and the USB pins are not exposed.

Pin state resets to all-inputs on power cycle or USB reconnect. Applications
should set required modes explicitly at startup.

---

## Filesystem layout

```
/mnt/rp2040/
└── gpio/
    └── gpioN/
        ├── mode        r/w  "in" | "out" | "pwm" | "adc"
        ├── value       r/w  depends on mode (see below)
        ├── pull        r/w  "none" | "up" | "down"
        ├── pwm_freq    r/w  frequency in Hz (8-62500000)
        └── pwm_duty    r/w  duty cycle 0-65535 (0-100%)
```

### value file by mode

| Mode | Read | Write |
|------|------|-------|
| in   | 0 or 1 | — |
| out  | 0 or 1 | 0 or 1 |
| pwm  | current duty cycle | — |
| adc  | raw_12bit volts e.g. 2048 1.6504 | — |

### pull file

Only meaningful in in mode. Accepted values: none, up, down.

### pwm_freq and pwm_duty

Only meaningful in pwm mode.

- pwm_freq: integer Hz, range 8-62,500,000
- pwm_duty: integer 0-65535 (0=0%, 65535=100%)

The firmware automatically selects the optimal clock prescaler to maximise
duty cycle resolution at the requested frequency.

### ADC specification

- Reference voltage: 3.3V, 12-bit resolution (0-4095 raw counts)
- Raw sample rate: 2,000 Sa/s
- Averages per read: 32 samples
- Time per read: ~16ms
- Maximum read rate: ~62 reads/second per channel

---

## Quick install

On any Ubuntu machine, clone the repo and run the installer:

```bash
git clone https://github.com/Josh3-14159/rp2040-gpio-fs.git
cd rp2040-gpio-fs/linux
chmod +x install.sh
./install.sh
```

The installer will:
- Install required system packages (`libfuse3-dev`, `gcc`, etc.)
- Build and install the `rp2040fs` FUSE daemon
- Install the udev rule so the board is recognised on plug-in
- Install the systemd service so the filesystem mounts automatically
- Create `/mnt/rp2040` with correct permissions
- Add your user to the `dialout` group

Then flash the firmware to the board:
1. Hold **BOOT** on the RP2040 Zero
2. Plug in USB while holding BOOT — release BOOT
3. Copy the pre-compiled UF2:

```bash
cp firmware/rp2040_gpio_fs.uf2 /media/$USER/RPI-RP2/
```

Plug the board back in normally — the filesystem mounts at `/mnt/rp2040` automatically.

> **Note:** If you were added to the `dialout` group during installation, log out and back in before use.

---

## Repository layout

```
rp2040-gpio-fs/
├── README.md
├── firmware/
│   ├── CMakeLists.txt
│   ├── main.c
│   ├── usb_descriptors.c
│   └── tusb_config.h
├── linux/
│   ├── config/
│   │   ├── 99-rp2040-gpio-fs.rules   udev rule
│   │   └── rp2040fs@.service         systemd service template
│   └── fs_app/
│       ├── rp2040fs.c                FUSE daemon source
│       ├── Makefile
│       ├── README.md
│       └── mount_rp2040.sh           convenience mount script
└── test/
    └── stress_test.sh
```

---

## Building the firmware

### Prerequisites

- arm-none-eabi-gcc toolchain
- cmake >= 3.13
- pico-sdk at /opt/pico-sdk (update PICO_SDK_PATH in CMakeLists.txt if different)
- picotool >= 2.0 installed and registered with cmake (required for UF2 generation)

### Install picotool

```bash
sudo apt install build-essential pkg-config libusb-1.0-0-dev cmake git

git clone https://github.com/raspberrypi/picotool.git
cd picotool && mkdir build && cd build
cmake .. -DPICO_SDK_PATH=/opt/pico-sdk
make -j$(nproc)
sudo cmake --install .

sudo cp ../udev/60-picotool.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Build

```bash
cd firmware
mkdir build && cd build
cmake ..
make -j$(nproc)
```

Output: firmware/build/rp2040_gpio_fs.uf2

### Flash

1. Hold BOOT on the RP2040 Zero
2. Plug in USB while holding BOOT
3. Release BOOT — board appears as RPI-RP2 mass storage
4. Copy the UF2:

```bash
cp firmware/build/rp2040_gpio_fs.uf2 /media/$USER/RPI-RP2/
```

The board reboots automatically and enumerates as cafe:4001 Waveshare RP2040 GPIO FS.

---

## Building the Linux daemon

### Prerequisites

```bash
sudo apt install libfuse3-dev pkg-config gcc
```

### Build

```bash
cd linux/fs_app
make
```

### Install

```bash
sudo cp rp2040fs /usr/local/bin/
sudo chmod +x /usr/local/bin/rp2040fs
```

---

## System integration (udev + systemd)

Enables the filesystem to mount automatically when the board is plugged in
and unmount cleanly when it is removed.

### Mount point and permissions

```bash
sudo mkdir -p /mnt/rp2040
sudo chown $USER:$USER /mnt/rp2040
sudo usermod -a -G dialout $USER
# Log out and back in after adding to dialout
```

### Install udev rule

```bash
sudo cp linux/config/99-rp2040-gpio-fs.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Creates a stable symlink at /dev/rp2040_gpio_fs regardless of ttyACMx number.

### Install systemd service

The service is a template unit — the instance name is your username.

```bash
sudo cp linux/config/rp2040fs@.service /etc/systemd/system/
sudo systemctl daemon-reload
```

The service starts and stops automatically via udev. To manage manually:

```bash
systemctl start rp2040fs@$USER
systemctl stop rp2040fs@$USER
systemctl status rp2040fs@$USER
sudo journalctl -fu rp2040fs@$USER
```

---

## Manual mount / unmount

```bash
# Mount
rp2040fs /mnt/rp2040 --device /dev/rp2040_gpio_fs

# Unmount
fusermount3 -u /mnt/rp2040

# Or use the convenience script
chmod +x linux/fs_app/mount_rp2040.sh
./linux/fs_app/mount_rp2040.sh
./linux/fs_app/mount_rp2040.sh unmount
```

---

## Reliability

The daemon includes:

- Serial reconnection: closes and reopens the port after 3 consecutive errors,
  retrying for up to 10 seconds
- Watchdog thread: pings firmware every 10 seconds, triggers reconnection if
  no response
- DTR assertion: required for the Linux CDC driver to communicate
- systemd integration: bound to the udev device, auto-starts on plug,
  stops on unplug

---

## Testing

```bash
chmod +x test/stress_test.sh

# Basic run
./test/stress_test.sh /mnt/rp2040 100

# Heavy stress
./test/stress_test.sh /mnt/rp2040 1000

# With loopback test (wire GP0 to GP1)
LOOPBACK=1 ./test/stress_test.sh /mnt/rp2040 100
```

Covers pull resistor states, mode persistence, PWM configuration, ADC format
and range, error handling, and rapid sequential reads.

---

## Protocol reference

USB CDC at 115200 8N1. Commands are newline-terminated ASCII.

| Command | Response |
|---------|----------|
| PING | PONG |
| MODE pin in/out/pwm/adc | OK or ERR ... |
| GETMODE pin | VAL mode |
| GET pin | VAL 0/1 or ADC raw volts |
| SET pin 0/1 | OK or ERR ... |
| PULL pin none/up/down | OK or ERR ... |
| GETPULL pin | VAL state |
| PWM_FREQ pin hz | OK or ERR ... |
| PWM_DUTY pin 0-65535 | OK or ERR ... |

### Manual testing via Python

```bash
python3 - << 'EOF'
import serial, time
s = serial.Serial('/dev/ttyACM0', 115200, timeout=2)
s.dtr = True
time.sleep(0.5)
s.write(b'PING\n')
print(s.readline().decode().strip())
s.close()
EOF
```

---

## USB device identity

| Field | Value |
|-------|-------|
| Vendor ID | 0xCAFE |
| Product ID | 0x4001 |
| Manufacturer | Waveshare |
| Product | RP2040 GPIO FS |
