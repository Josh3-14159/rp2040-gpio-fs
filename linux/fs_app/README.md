# RP2040 GPIO Filesystem

Exposes the GPIO, ADC, and PWM peripherals of an RP2040 Zero as a FUSE
filesystem on Linux. Interact with hardware by reading and writing files.

## Repository layout

```
rp2040_gpio_fs/
├── firmware/
│   ├── CMakeLists.txt
│   └── src/
│       ├── main.c
│       ├── usb_descriptors.c
│       └── tusb_config.h
└── linux/
    ├── rp2040fs.c
    ├── Makefile
    ├── 99-rp2040-gpio-fs.rules
    └── mount_rp2040.sh
```

## Exposed pins

GP0–GP22, GP26, GP27, GP28, GP29 (24 pins total).
ADC capable: GP26 (ADC0), GP27 (ADC1), GP28 (ADC2), GP29 (ADC3).
All pins support in / out / pwm modes.

## Filesystem layout

```
/mnt/rp2040/
└── gpio/
    └── gpioN/
        ├── mode        r/w  "in" | "out" | "pwm" | "adc"
        ├── value       r/w  depends on mode (see below)
        ├── pull        r/w  "none" | "up" | "down"
        ├── pwm_freq    r/w  frequency in Hz
        └── pwm_duty    r/w  duty cycle 0–65535
```

### value file behaviour by mode

| mode | read            | write          |
|------|-----------------|----------------|
| in   | "0" or "1"      | not applicable |
| out  | not applicable  | "0" or "1"     |
| pwm  | current duty    | not applicable |
| adc  | "raw volts"     | not applicable |

ADC example output: `2048 1.6504`

## Build — Firmware

Prerequisites: pico-sdk at /opt/pico-sdk, cmake, arm-none-eabi-gcc.

```bash
cd firmware
mkdir build && cd build
cmake ..
make -j$(nproc)
```

Flash `rp2040_gpio_fs.uf2` to the board:
- Hold BOOTSEL, plug in USB, release BOOTSEL
- Copy the .uf2 to the RPI-RP2 mass storage device

## Build — Linux daemon

Prerequisites: libfuse3-dev, pkg-config, gcc.

```bash
sudo apt install libfuse3-dev pkg-config   # Debian/Ubuntu
cd linux
make
```

## Install udev rule

```bash
sudo cp linux/99-rp2040-gpio-fs.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

This creates a `/dev/rp2040_gpio_fs` symlink and sets permissions to 0666
so you do not need sudo or dialout group membership.

## Mount

```bash
sudo mkdir -p /mnt/rp2040
chmod +x linux/mount_rp2040.sh
./linux/mount_rp2040.sh
```

To unmount:
```bash
./linux/mount_rp2040.sh unmount
```

## Usage examples

```bash
# Set GP15 as output and drive high
echo "out" > /mnt/rp2040/gpio/gpio15/mode
echo "1"   > /mnt/rp2040/gpio/gpio15/value

# Read digital input on GP4 with pull-up
echo "in"  > /mnt/rp2040/gpio/gpio4/mode
echo "up"  > /mnt/rp2040/gpio/gpio4/pull
cat /mnt/rp2040/gpio/gpio4/value

# 1kHz PWM at 50% duty on GP0
echo "pwm"   > /mnt/rp2040/gpio/gpio0/mode
echo "1000"  > /mnt/rp2040/gpio/gpio0/pwm_freq
echo "32768" > /mnt/rp2040/gpio/gpio0/pwm_duty

# Read ADC on GP26
echo "adc" > /mnt/rp2040/gpio/gpio26/mode
cat /mnt/rp2040/gpio/gpio26/value
# → 2048 1.6504
```

## ADC specification

- Raw sample rate: 2,000 Sa/s (adc_set_clkdiv(249.0))
- Averages per read: 32 samples
- Time per read: ~16 ms
- Maximum read rate: ~62.5 reads/second per channel
- Reference voltage: 3.3V, 12-bit (0–4095)

## Protocol reference (USB CDC, 115200 8N1)

| Command               | Response              |
|-----------------------|-----------------------|
| PING                  | PONG                  |
| MODE \<pin\> \<mode\> | OK / ERR ...          |
| GETMODE \<pin\>       | VAL \<mode\>          |
| GET \<pin\>           | VAL \<n\> or ADC \<raw\> \<v\> |
| SET \<pin\> \<0\|1\>  | OK / ERR ...          |
| PULL \<pin\> \<state\>| OK / ERR ...          |
| GETPULL \<pin\>       | VAL \<state\>         |
| PWM_FREQ \<pin\> \<hz\>| OK / ERR ...         |
| PWM_DUTY \<pin\> \<n\>| OK / ERR ...          |
