#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>

#include "pico/stdlib.h"
#include "pico/unique_id.h"
#include "hardware/gpio.h"
#include "hardware/adc.h"
#include "hardware/pwm.h"
#include "tusb.h"

static const uint8_t EXPOSED_PINS[] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,
    26,27,28,29
};
#define NUM_PINS 27

static inline int pin_to_adc_channel(uint8_t pin) {
    if (pin == 26) return 0;
    if (pin == 27) return 1;
    if (pin == 28) return 2;
    if (pin == 29) return 3;
    return -1;
}

static inline bool pin_is_exposed(uint8_t pin) {
    for (int i = 0; i < NUM_PINS; i++)
        if (EXPOSED_PINS[i] == pin) return true;
    return false;
}

typedef enum { MODE_IN, MODE_OUT, MODE_PWM, MODE_ADC } pin_mode_t;
typedef enum { PULL_NONE, PULL_UP, PULL_DOWN } pull_state_t;

typedef struct {
    pin_mode_t   mode;
    pull_state_t pull;
    uint32_t     pwm_freq;
    uint16_t     pwm_duty;
    bool         initialised;
} pin_state_t;

static pin_state_t pin_states[30];
static void set_pwm_freq_duty(uint8_t pin);

#define ADC_CLKDIV      249.0f
#define ADC_AVG_SAMPLES 32

#define RX_BUF_LEN 128
#define TX_BUF_LEN 128

static char rx_buf[RX_BUF_LEN];
static uint32_t rx_pos = 0;

static void cdc_send(const char *msg) {
    if (!tud_cdc_write_available()) return;
    uint32_t len = strlen(msg);
    uint32_t sent = 0;
    while (sent < len) {
        uint32_t n = tud_cdc_write(msg + sent, len - sent);
        sent += n;
        tud_task();
    }
    tud_cdc_write_flush();
}

static void apply_pull(uint8_t pin, pull_state_t pull) {
    switch (pull) {
        case PULL_UP:   gpio_pull_up(pin);       break;
        case PULL_DOWN: gpio_pull_down(pin);     break;
        case PULL_NONE:
        default:        gpio_disable_pulls(pin); break;
    }
}

static void pwm_stop(uint8_t pin) {
    uint slice = pwm_gpio_to_slice_num(pin);
    pwm_set_enabled(slice, false);
    gpio_set_function(pin, GPIO_FUNC_SIO);
}

static void set_pin_mode(uint8_t pin, pin_mode_t mode) {
    pin_state_t *s = &pin_states[pin];
    if (s->initialised && s->mode == MODE_PWM)
        pwm_stop(pin);
    switch (mode) {
        case MODE_IN:
            gpio_set_function(pin, GPIO_FUNC_SIO);
            gpio_set_dir(pin, GPIO_IN);
            apply_pull(pin, s->pull);
            break;
        case MODE_OUT:
            gpio_set_function(pin, GPIO_FUNC_SIO);
            gpio_set_dir(pin, GPIO_OUT);
            gpio_disable_pulls(pin);
            gpio_put(pin, 0);
            break;
        case MODE_PWM: {
            gpio_set_function(pin, GPIO_FUNC_PWM);
            if (s->pwm_freq == 0) s->pwm_freq = 1000;
            set_pwm_freq_duty(pin);
            break;
        }
        case MODE_ADC:
            gpio_set_function(pin, GPIO_FUNC_NULL);
            gpio_disable_pulls(pin);
            adc_gpio_init(pin);
            break;
    }
    s->mode = mode;
    s->initialised = true;
}

static void set_pwm_freq_duty(uint8_t pin) {
    pin_state_t *s = &pin_states[pin];
    uint slice = pwm_gpio_to_slice_num(pin);
    uint chan  = pwm_gpio_to_channel(pin);

    uint32_t freq = s->pwm_freq;
    if (freq == 0) freq = 1000;

    // Find smallest integer divider that keeps wrap within 16 bits
    uint32_t divider = (125000000u + (freq * 65536u) - 1) / (freq * 65536u);
    if (divider < 1)   divider = 1;
    if (divider > 255) divider = 255;

    uint32_t wrap = (125000000u / (divider * freq)) - 1;
    if (wrap > 65535) wrap = 65535;
    if (wrap < 1)     wrap = 1;

    // Scale duty from 0-65535 to 0-wrap
    uint32_t level = ((uint32_t)s->pwm_duty * (wrap + 1)) >> 16;

    pwm_set_enabled(slice, false);
    pwm_set_clkdiv_int_frac(slice, (uint8_t)divider, 0);
    pwm_set_wrap(slice, (uint16_t)wrap);
    pwm_set_chan_level(slice, chan, (uint16_t)level);
    pwm_set_enabled(slice, true);
}

static uint16_t adc_read_averaged(int channel) {
    adc_select_input(channel);
    uint32_t sum = 0;
    for (int i = 0; i < ADC_AVG_SAMPLES; i++) {
        sum += adc_read();
        tight_loop_contents();
    }
    return (uint16_t)(sum / ADC_AVG_SAMPLES);
}

static void handle_command(char *line) {
    char resp[TX_BUF_LEN];
    int len = strlen(line);
    while (len > 0 && (line[len-1] == '\r' || line[len-1] == '\n' || line[len-1] == ' '))
        line[--len] = '\0';
    if (len == 0) return;

    char *tok = strtok(line, " ");
    if (!tok) return;

    if (strcmp(tok, "PING") == 0) {
        cdc_send("PONG\n");
        return;
    }

    char *pin_str = strtok(NULL, " ");
    if (!pin_str) { cdc_send("ERR missing pin\n"); return; }
    int pin = atoi(pin_str);
    if (pin < 0 || pin > 29 || !pin_is_exposed((uint8_t)pin)) {
        cdc_send("ERR invalid pin\n");
        return;
    }
    pin_state_t *s = &pin_states[pin];

    if (strcmp(tok, "MODE") == 0) {
        char *m = strtok(NULL, " ");
        if (!m) { cdc_send("ERR missing mode\n"); return; }
        pin_mode_t new_mode;
        if      (strcmp(m, "in")  == 0) new_mode = MODE_IN;
        else if (strcmp(m, "out") == 0) new_mode = MODE_OUT;
        else if (strcmp(m, "pwm") == 0) new_mode = MODE_PWM;
        else if (strcmp(m, "adc") == 0) {
            if (pin_to_adc_channel(pin) < 0) {
                cdc_send("ERR pin not ADC capable\n");
                return;
            }
            new_mode = MODE_ADC;
        } else {
            cdc_send("ERR unknown mode\n");
            return;
        }
        set_pin_mode((uint8_t)pin, new_mode);
        cdc_send("OK\n");
        return;
    }

    if (strcmp(tok, "GETMODE") == 0) {
        if (!s->initialised) { cdc_send("VAL in\n"); return; }
        const char *modes[] = {"in","out","pwm","adc"};
        snprintf(resp, sizeof(resp), "VAL %s\n", modes[s->mode]);
        cdc_send(resp);
        return;
    }

    if (strcmp(tok, "GET") == 0) {
        if (!s->initialised) set_pin_mode((uint8_t)pin, MODE_IN);
        if (s->mode == MODE_IN) {
            snprintf(resp, sizeof(resp), "VAL %d\n", gpio_get((uint)pin) ? 1 : 0);
            cdc_send(resp);
        } else if (s->mode == MODE_ADC) {
            int ch = pin_to_adc_channel((uint8_t)pin);
            uint16_t raw = adc_read_averaged(ch);
            float voltage = (raw / 4095.0f) * 3.3f;
            snprintf(resp, sizeof(resp), "ADC %u %.4f\n", raw, (double)voltage);
            cdc_send(resp);
        } else if (s->mode == MODE_PWM) {
            snprintf(resp, sizeof(resp), "VAL %u\n", s->pwm_duty);
            cdc_send(resp);
        } else {
            cdc_send("ERR not applicable\n");
        }
        return;
    }

    if (strcmp(tok, "SET") == 0) {
        char *val_str = strtok(NULL, " ");
        if (!val_str) { cdc_send("ERR missing value\n"); return; }
        int val = atoi(val_str);
        if (!s->initialised) set_pin_mode((uint8_t)pin, MODE_OUT);
        if (s->mode != MODE_OUT) { cdc_send("ERR not applicable\n"); return; }
        gpio_put((uint)pin, val ? 1 : 0);
        cdc_send("OK\n");
        return;
    }

    if (strcmp(tok, "PULL") == 0) {
        char *p = strtok(NULL, " ");
        if (!p) { cdc_send("ERR missing pull state\n"); return; }
        pull_state_t pull;
        if      (strcmp(p, "none") == 0) pull = PULL_NONE;
        else if (strcmp(p, "up")   == 0) pull = PULL_UP;
        else if (strcmp(p, "down") == 0) pull = PULL_DOWN;
        else { cdc_send("ERR unknown pull state\n"); return; }
        s->pull = pull;
        if (s->initialised && s->mode == MODE_IN)
            apply_pull((uint8_t)pin, pull);
        cdc_send("OK\n");
        return;
    }

    if (strcmp(tok, "GETPULL") == 0) {
        const char *pulls[] = {"none","up","down"};
        snprintf(resp, sizeof(resp), "VAL %s\n", pulls[s->pull]);
        cdc_send(resp);
        return;
    }

    if (strcmp(tok, "PWM_FREQ") == 0) {
        char *hz_str = strtok(NULL, " ");
        if (!hz_str) { cdc_send("ERR missing frequency\n"); return; }
        uint32_t hz = (uint32_t)atoi(hz_str);
        if (hz == 0 || hz > 62500000) { cdc_send("ERR frequency out of range\n"); return; }
        // Minimum usable frequency with divider=255, wrap=65535
        if (hz < 8) { cdc_send("ERR frequency out of range\n"); return; }
        s->pwm_freq = hz;
        if (s->initialised && s->mode == MODE_PWM)
            set_pwm_freq_duty((uint8_t)pin);
        cdc_send("OK\n");
        return;
    }

    if (strcmp(tok, "PWM_DUTY") == 0) {
        char *duty_str = strtok(NULL, " ");
        if (!duty_str) { cdc_send("ERR missing duty\n"); return; }
        int duty = atoi(duty_str);
        if (duty < 0 || duty > 65535) { cdc_send("ERR duty out of range\n"); return; }
        s->pwm_duty = (uint16_t)duty;
        if (s->initialised && s->mode == MODE_PWM)
            set_pwm_freq_duty((uint8_t)pin);
        cdc_send("OK\n");
        return;
    }

    cdc_send("ERR unknown command\n");
}

int main(void) {
    memset(pin_states, 0, sizeof(pin_states));
    tusb_init();
    adc_init();
    adc_set_clkdiv(ADC_CLKDIV);

    while (true) {
        tud_task();
        if (tud_cdc_available()) {
            char c;
            while (tud_cdc_available()) {
                tud_cdc_read(&c, 1);
                if (c == '\n') {
                    rx_buf[rx_pos] = '\0';
                    handle_command(rx_buf);
                    rx_pos = 0;
                } else if (c != '\r') {
                    if (rx_pos < RX_BUF_LEN - 1) {
                        rx_buf[rx_pos++] = c;
                    } else {
                        rx_pos = 0;
                        cdc_send("ERR line too long\n");
                    }
                }
            }
        }
    }
}

void tud_cdc_line_state_cb(uint8_t itf, bool dtr, bool rts) {
    (void)itf; (void)dtr; (void)rts;
}

void tud_cdc_rx_cb(uint8_t itf) {
    (void)itf;
}
