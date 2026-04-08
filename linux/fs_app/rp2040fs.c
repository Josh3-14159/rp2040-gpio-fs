/*
 * rp2040fs.c — FUSE filesystem for RP2040 GPIO/ADC/PWM over USB CDC
 *
 * Build:
 *   gcc -Wall -O2 $(pkg-config fuse3 --cflags --libs) -o rp2040fs rp2040fs.c
 *
 * Mount:
 *   ./rp2040fs /mnt/rp2040 [--device /dev/ttyACM0]
 *
 * Unmount:
 *   fusermount3 -u /mnt/rp2040
 */

#define FUSE_USE_VERSION 31

#include <fuse3/fuse.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <pthread.h>
#include <stdarg.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/serial.h>

// ----------------------------------------------------------------
// Pin table — must match firmware
// ----------------------------------------------------------------
static const int EXPOSED_PINS[] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,
    26,27,28,29
};
#define NUM_PINS 27

static int adc_channel_for_pin(int pin) {
    if (pin == 26) return 0;
    if (pin == 27) return 1;
    if (pin == 28) return 2;
    if (pin == 29) return 3;
    return -1;
}

static int pin_is_exposed(int pin) {
    for (int i = 0; i < NUM_PINS; i++)
        if (EXPOSED_PINS[i] == pin) return 1;
    return 0;
}

// ----------------------------------------------------------------
// Serial port — with reconnection, retry, and protocol recovery
// ----------------------------------------------------------------
static int serial_fd = -1;
static pthread_mutex_t serial_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *device_path = "/dev/ttyACM0";
static int verbose = 0;

#define MAX_CONSECUTIVE_ERRORS 3
static int consecutive_errors = 0;

// Forward declaration — serial_reconnect calls serial_cmd
static int serial_cmd(const char *command, char *resp, size_t resp_len);

static int serial_open(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_SYNC);
    if (fd < 0) return -1;

    struct termios tty;
    if (tcgetattr(fd, &tty) < 0) { close(fd); return -1; }

    cfsetispeed(&tty, B115200);
    cfsetospeed(&tty, B115200);

    tty.c_cflag = (tty.c_cflag & ~CSIZE) | CS8;
    tty.c_cflag &= ~(PARENB | PARODD | CSTOPB | CRTSCTS);
    tty.c_cflag |= CREAD | CLOCAL;

    tty.c_iflag = 0;
    tty.c_oflag = 0;
    tty.c_lflag = 0;

    tty.c_cc[VMIN]  = 0;
    tty.c_cc[VTIME] = 10;

    if (tcsetattr(fd, TCSANOW, &tty) < 0) { close(fd); return -1; }
    tcflush(fd, TCIOFLUSH);

    int modem_flags;
    ioctl(fd, TIOCMGET, &modem_flags);
    modem_flags |= TIOCM_DTR;
    ioctl(fd, TIOCMSET, &modem_flags);

    usleep(100000);
    return fd;
}

static int serial_reconnect(void) {
    fprintf(stderr, "Serial: reconnecting to %s...\n", device_path);
    if (serial_fd >= 0) {
        close(serial_fd);
        serial_fd = -1;
    }

    for (int i = 0; i < 10; i++) {
        serial_fd = serial_open(device_path);
        if (serial_fd >= 0) {
            char resp[64];
            if (serial_cmd("PING", resp, sizeof(resp)) == 0 &&
                strcmp(resp, "PONG") == 0) {
                fprintf(stderr, "Serial: reconnected OK.\n");
                consecutive_errors = 0;
                return 0;
            }
            close(serial_fd);
            serial_fd = -1;
        }
        sleep(1);
    }

    fprintf(stderr, "Serial: reconnect failed after 10 attempts.\n");
    return -1;
}

static int serial_cmd(const char *command, char *resp, size_t resp_len) {
    if (serial_fd < 0) return -1;

    tcflush(serial_fd, TCIFLUSH);

    char buf[256];
    snprintf(buf, sizeof(buf), "%s\n", command);
    ssize_t w = write(serial_fd, buf, strlen(buf));
    if (w < 0) return -1;

    size_t pos = 0;
    char c;
    while (pos < resp_len - 1) {
        ssize_t r = read(serial_fd, &c, 1);
        if (r <= 0) return -1;
        if (c == '\n') break;
        if (c != '\r') resp[pos++] = c;
    }
    resp[pos] = '\0';
    return 0;
}

static char *cmd(const char *fmt, ...) {
    static char resp[256];
    char cmdbuf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmdbuf, sizeof(cmdbuf), fmt, ap);
    va_end(ap);

    for (int attempt = 0; attempt < 2; attempt++) {
        if (serial_fd < 0) {
            if (serial_reconnect() < 0) return NULL;
        }

        if (serial_cmd(cmdbuf, resp, sizeof(resp)) == 0) {
            consecutive_errors = 0;
            if (verbose)
                fprintf(stderr, "CMD: %s -> %s\n", cmdbuf, resp);
            return resp;
        }

        consecutive_errors++;
        fprintf(stderr, "Serial: command '%s' failed (error %d/%d)\n",
                cmdbuf, consecutive_errors, MAX_CONSECUTIVE_ERRORS);

        if (consecutive_errors >= MAX_CONSECUTIVE_ERRORS) {
            fprintf(stderr, "Serial: too many errors, forcing reconnect.\n");
            if (serial_reconnect() < 0) return NULL;
        }
    }

    return NULL;
}

// ----------------------------------------------------------------
// Watchdog thread — pings firmware every 10s, reconnects if dead
// ----------------------------------------------------------------
static void *watchdog_thread(void *arg) {
    (void)arg;
    while (1) {
        sleep(10);
        pthread_mutex_lock(&serial_lock);
        char *resp = cmd("PING");
        if (!resp || strcmp(resp, "PONG") != 0) {
            fprintf(stderr, "Watchdog: firmware not responding, reconnecting.\n");
            serial_reconnect();
        }
        pthread_mutex_unlock(&serial_lock);
    }
    return NULL;
}

// ----------------------------------------------------------------
// Virtual filesystem structure
//
// Paths:
//   /                          — root dir
//   /gpio/                     — gpio dir
//   /gpio/gpioN/               — per-pin dir
//   /gpio/gpioN/mode           — file
//   /gpio/gpioN/value          — file
//   /gpio/gpioN/pull           — file
//   /gpio/gpioN/pwm_freq       — file
//   /gpio/gpioN/pwm_duty       — file
// ----------------------------------------------------------------

typedef enum {
    NODE_ROOT,
    NODE_GPIO_DIR,
    NODE_PIN_DIR,
    NODE_FILE_MODE,
    NODE_FILE_VALUE,
    NODE_FILE_PULL,
    NODE_FILE_PWM_FREQ,
    NODE_FILE_PWM_DUTY,
    NODE_UNKNOWN
} node_type_t;

typedef struct {
    node_type_t type;
    int pin;
} path_info_t;

static path_info_t parse_path(const char *path) {
    path_info_t info = { NODE_UNKNOWN, -1 };

    if (strcmp(path, "/") == 0) {
        info.type = NODE_ROOT;
        return info;
    }

    if (strcmp(path, "/gpio") == 0 || strcmp(path, "/gpio/") == 0) {
        info.type = NODE_GPIO_DIR;
        return info;
    }

    if (strncmp(path, "/gpio/gpio", 10) != 0) return info;

    const char *rest = path + 10;
    char *slash = strchr(rest, '/');

    int pin;
    if (slash == NULL) {
        pin = atoi(rest);
        if (!pin_is_exposed(pin)) return info;
        info.type = NODE_PIN_DIR;
        info.pin  = pin;
        return info;
    }

    char pinstr[8];
    size_t plen = slash - rest;
    if (plen >= sizeof(pinstr)) return info;
    strncpy(pinstr, rest, plen);
    pinstr[plen] = '\0';
    pin = atoi(pinstr);
    if (!pin_is_exposed(pin)) return info;

    const char *fname = slash + 1;
    info.pin = pin;

    if      (strcmp(fname, "mode")     == 0) info.type = NODE_FILE_MODE;
    else if (strcmp(fname, "value")    == 0) info.type = NODE_FILE_VALUE;
    else if (strcmp(fname, "pull")     == 0) info.type = NODE_FILE_PULL;
    else if (strcmp(fname, "pwm_freq") == 0) info.type = NODE_FILE_PWM_FREQ;
    else if (strcmp(fname, "pwm_duty") == 0) info.type = NODE_FILE_PWM_DUTY;

    return info;
}

// ----------------------------------------------------------------
// FUSE operations
// ----------------------------------------------------------------

static int rp_getattr(const char *path, struct stat *st,
                      struct fuse_file_info *fi) {
    (void)fi;
    memset(st, 0, sizeof(*st));

    path_info_t info = parse_path(path);

    switch (info.type) {
        case NODE_ROOT:
        case NODE_GPIO_DIR:
        case NODE_PIN_DIR:
            st->st_mode  = S_IFDIR | 0755;
            st->st_nlink = 2;
            return 0;

        case NODE_FILE_MODE:
        case NODE_FILE_VALUE:
        case NODE_FILE_PULL:
        case NODE_FILE_PWM_FREQ:
        case NODE_FILE_PWM_DUTY:
            st->st_mode  = S_IFREG | 0666;
            st->st_nlink = 1;
            st->st_size  = 64;
            return 0;

        default:
            return -ENOENT;
    }
}

static int rp_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                      off_t offset, struct fuse_file_info *fi,
                      enum fuse_readdir_flags flags) {
    (void)offset; (void)fi; (void)flags;

    path_info_t info = parse_path(path);

    filler(buf, ".",  NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);

    if (info.type == NODE_ROOT) {
        filler(buf, "gpio", NULL, 0, 0);
        return 0;
    }

    if (info.type == NODE_GPIO_DIR) {
        char name[16];
        for (int i = 0; i < NUM_PINS; i++) {
            snprintf(name, sizeof(name), "gpio%d", EXPOSED_PINS[i]);
            filler(buf, name, NULL, 0, 0);
        }
        return 0;
    }

    if (info.type == NODE_PIN_DIR) {
        filler(buf, "mode",     NULL, 0, 0);
        filler(buf, "value",    NULL, 0, 0);
        filler(buf, "pull",     NULL, 0, 0);
        filler(buf, "pwm_freq", NULL, 0, 0);
        filler(buf, "pwm_duty", NULL, 0, 0);
        return 0;
    }

    return -ENOTDIR;
}

static int rp_open(const char *path, struct fuse_file_info *fi) {
    path_info_t info = parse_path(path);
    if (info.type == NODE_UNKNOWN || info.type == NODE_ROOT ||
        info.type == NODE_GPIO_DIR || info.type == NODE_PIN_DIR)
        return -ENOENT;
    return 0;
}

static int rp_read(const char *path, char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)fi;
    path_info_t info = parse_path(path);
    if (info.type == NODE_UNKNOWN) return -ENOENT;

    char content[128] = "";
    int pin = info.pin;

    pthread_mutex_lock(&serial_lock);

    char *resp;
    switch (info.type) {
        case NODE_FILE_MODE: {
            resp = cmd("GETMODE %d", pin);
            if (!resp) { pthread_mutex_unlock(&serial_lock); return -EIO; }
            if (strncmp(resp, "VAL ", 4) == 0)
                snprintf(content, sizeof(content), "%s\n", resp + 4);
            else
                snprintf(content, sizeof(content), "%s\n", resp);
            break;
        }

        case NODE_FILE_VALUE: {
            resp = cmd("GET %d", pin);
            if (!resp) { pthread_mutex_unlock(&serial_lock); return -EIO; }
            if (strncmp(resp, "VAL ", 4) == 0)
                snprintf(content, sizeof(content), "%s\n", resp + 4);
            else if (strncmp(resp, "ADC ", 4) == 0)
                snprintf(content, sizeof(content), "%s\n", resp + 4);
            else
                snprintf(content, sizeof(content), "%s\n", resp);
            break;
        }

        case NODE_FILE_PULL: {
            resp = cmd("GETPULL %d", pin);
            if (!resp) { pthread_mutex_unlock(&serial_lock); return -EIO; }
            if (strncmp(resp, "VAL ", 4) == 0)
                snprintf(content, sizeof(content), "%s\n", resp + 4);
            else
                snprintf(content, sizeof(content), "%s\n", resp);
            break;
        }

        case NODE_FILE_PWM_FREQ:
        case NODE_FILE_PWM_DUTY: {
            resp = cmd("GETMODE %d", pin);
            if (!resp) { pthread_mutex_unlock(&serial_lock); return -EIO; }
            if (strcmp(resp, "VAL pwm") != 0) {
                snprintf(content, sizeof(content), "ERR not applicable\n");
            } else {
                resp = cmd("GET %d", pin);
                if (!resp) { pthread_mutex_unlock(&serial_lock); return -EIO; }
                if (strncmp(resp, "VAL ", 4) == 0)
                    snprintf(content, sizeof(content), "%s\n", resp + 4);
                else
                    snprintf(content, sizeof(content), "%s\n", resp);
            }
            break;
        }

        default:
            pthread_mutex_unlock(&serial_lock);
            return -ENOENT;
    }

    pthread_mutex_unlock(&serial_lock);

    size_t clen = strlen(content);
    if (offset >= (off_t)clen) return 0;
    size_t available = clen - offset;
    size_t n = available < size ? available : size;
    memcpy(buf, content + offset, n);
    return (int)n;
}

static int rp_write(const char *path, const char *buf, size_t size,
                    off_t offset, struct fuse_file_info *fi) {
    (void)fi; (void)offset;
    path_info_t info = parse_path(path);
    if (info.type == NODE_UNKNOWN) return -ENOENT;

    int pin = info.pin;

    char input[128];
    size_t n = size < sizeof(input) - 1 ? size : sizeof(input) - 1;
    memcpy(input, buf, n);
    input[n] = '\0';
    int l = strlen(input);
    while (l > 0 && (input[l-1] == '\n' || input[l-1] == '\r' || input[l-1] == ' '))
        input[--l] = '\0';

    char cmdbuf[128];
    char *resp;

    pthread_mutex_lock(&serial_lock);

    switch (info.type) {
        case NODE_FILE_MODE:
            snprintf(cmdbuf, sizeof(cmdbuf), "MODE %d %s", pin, input);
            resp = cmd("%s", cmdbuf);
            break;
        case NODE_FILE_VALUE:
            snprintf(cmdbuf, sizeof(cmdbuf), "SET %d %s", pin, input);
            resp = cmd("%s", cmdbuf);
            break;
        case NODE_FILE_PULL:
            snprintf(cmdbuf, sizeof(cmdbuf), "PULL %d %s", pin, input);
            resp = cmd("%s", cmdbuf);
            break;
        case NODE_FILE_PWM_FREQ:
            snprintf(cmdbuf, sizeof(cmdbuf), "PWM_FREQ %d %s", pin, input);
            resp = cmd("%s", cmdbuf);
            break;
        case NODE_FILE_PWM_DUTY:
            snprintf(cmdbuf, sizeof(cmdbuf), "PWM_DUTY %d %s", pin, input);
            resp = cmd("%s", cmdbuf);
            break;
        default:
            pthread_mutex_unlock(&serial_lock);
            return -ENOENT;
    }

    pthread_mutex_unlock(&serial_lock);

    if (!resp) return -EIO;
    if (strncmp(resp, "ERR", 3) == 0) return -EINVAL;
    return (int)size;
}

// ----------------------------------------------------------------
// FUSE ops table
// ----------------------------------------------------------------
static const struct fuse_operations rp_ops = {
    .getattr = rp_getattr,
    .readdir = rp_readdir,
    .open    = rp_open,
    .read    = rp_read,
    .write   = rp_write,
};

// ----------------------------------------------------------------
// main
// ----------------------------------------------------------------
static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s <mountpoint> [FUSE options] [--device <tty>]\n"
        "  --device   Serial device (default: /dev/ttyACM0)\n",
        prog);
}

int main(int argc, char *argv[]) {
    struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
    fuse_opt_add_arg(&args, argv[0]);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            device_path = argv[++i];
        } else if (strcmp(argv[i], "--verbose") == 0 ||
                   strcmp(argv[i], "-v") == 0) {
            verbose = 1;
        } else {
            fuse_opt_add_arg(&args, argv[i]);
        }
    }

    serial_fd = serial_open(device_path);
    if (serial_fd < 0) {
        fprintf(stderr, "Error: cannot open serial device %s\n", device_path);
        return 1;
    }
    fprintf(stderr, "Connected to %s\n", device_path);

    pthread_mutex_lock(&serial_lock);
    char *resp = cmd("PING");
    pthread_mutex_unlock(&serial_lock);
    if (!resp || strcmp(resp, "PONG") != 0) {
        fprintf(stderr, "Warning: device did not respond to PING (got: %s)\n",
                resp ? resp : "<timeout>");
    } else {
        fprintf(stderr, "Device alive.\n");
    }

    pthread_t wdog;
    pthread_create(&wdog, NULL, watchdog_thread, NULL);
    pthread_detach(wdog);

    fuse_opt_add_arg(&args, "-s");
    fuse_opt_add_arg(&args, "-f");

    int ret = fuse_main(args.argc, args.argv, &rp_ops, NULL);

    close(serial_fd);
    fuse_opt_free_args(&args);
    return ret;
}
