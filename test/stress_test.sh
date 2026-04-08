#!/usr/bin/env bash
# stress_test.sh — reliability test for rp2040 GPIO filesystem
# Tests digital I/O, pull states, ADC, and PWM in a continuous loop
#
# Usage:
#   ./stress_test.sh [mountpoint] [iterations]
#   ./stress_test.sh /mnt/rp2040 1000

set -euo pipefail

MOUNT="${1:-/mnt/rp2040}"
ITERATIONS="${2:-100}"

# ----------------------------------------------------------------
# Colour output
# ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}  PASS${NC} $1"; }
fail() { echo -e "${RED}  FAIL${NC} $1"; FAILURES=$((FAILURES+1)); }
info() { echo -e "${YELLOW}  ----${NC} $1"; }

FAILURES=0
TOTAL=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL+1))
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc — expected='$expected' got='$actual'"
    fi
}

# ----------------------------------------------------------------
# Check mount is present
# ----------------------------------------------------------------
if ! mountpoint -q "$MOUNT"; then
    echo "Error: $MOUNT is not mounted. Start the daemon first."
    exit 1
fi

echo "========================================"
echo " RP2040 GPIO FS Reliability Test"
echo " Mount:      $MOUNT"
echo " Iterations: $ITERATIONS"
echo "========================================"

# ----------------------------------------------------------------
# Test 1: Pull resistor states on GP0 (nothing connected)
# ----------------------------------------------------------------
info "Test 1: Pull resistor states (GP0, floating)"

echo "in"   > "$MOUNT/gpio/gpio0/mode"

echo "up"   > "$MOUNT/gpio/gpio0/pull"
check "pull=up   → value=1" "1" "$(cat $MOUNT/gpio/gpio0/value)"
check "getpull=up"          "up" "$(cat $MOUNT/gpio/gpio0/pull)"

echo "down" > "$MOUNT/gpio/gpio0/pull"
check "pull=down → value=0" "0" "$(cat $MOUNT/gpio/gpio0/value)"
check "getpull=down"        "down" "$(cat $MOUNT/gpio/gpio0/pull)"

echo "none" > "$MOUNT/gpio/gpio0/pull"
check "getpull=none"        "none" "$(cat $MOUNT/gpio/gpio0/pull)"

# ----------------------------------------------------------------
# Test 2: Output→Input loopback (GP0 → GP1, wire these together)
# ----------------------------------------------------------------
info "Test 2: Output→Input loopback (requires GP0 wired to GP1)"

if [ "${LOOPBACK:-0}" = "1" ]; then
    echo "out"  > "$MOUNT/gpio/gpio0/mode"
    echo "in"   > "$MOUNT/gpio/gpio1/mode"

    # Use pull-down on GP1 so a floating (unjumpered) pin always reads 0.
    # With the jumper connected, GP0 driving high will overcome the pull-down
    # and GP1 will read 1 — proving the loopback is real.
    echo "down" > "$MOUNT/gpio/gpio1/pull"

    echo "1" > "$MOUNT/gpio/gpio0/value"
    check "loopback high: GP1 reads 1" "1" "$(cat $MOUNT/gpio/gpio1/value)"

    echo "0" > "$MOUNT/gpio/gpio0/value"
    check "loopback low:  GP1 reads 0" "0" "$(cat $MOUNT/gpio/gpio1/value)"
else
    echo "  Skipping — wire GP0 to GP1 and re-run with LOOPBACK=1 to enable"
fi

# ----------------------------------------------------------------
# Test 3: Mode persistence
# ----------------------------------------------------------------
info "Test 3: Mode persistence"

echo "in"  > "$MOUNT/gpio/gpio2/mode"
check "mode set to in"  "in"  "$(cat $MOUNT/gpio/gpio2/mode)"

echo "out" > "$MOUNT/gpio/gpio2/mode"
check "mode set to out" "out" "$(cat $MOUNT/gpio/gpio2/mode)"

echo "pwm" > "$MOUNT/gpio/gpio2/mode"
check "mode set to pwm" "pwm" "$(cat $MOUNT/gpio/gpio2/mode)"

echo "in"  > "$MOUNT/gpio/gpio2/mode"
check "mode back to in" "in"  "$(cat $MOUNT/gpio/gpio2/mode)"

# ----------------------------------------------------------------
# Test 4: PWM frequency and duty
# ----------------------------------------------------------------
info "Test 4: PWM configuration (GP3)"

echo "pwm"   > "$MOUNT/gpio/gpio3/mode"
echo "1000"  > "$MOUNT/gpio/gpio3/pwm_freq"
echo "32768" > "$MOUNT/gpio/gpio3/pwm_duty"
check "pwm duty readback" "32768" "$(cat $MOUNT/gpio/gpio3/pwm_duty)"

echo "65535" > "$MOUNT/gpio/gpio3/pwm_duty"
check "pwm duty 100%"     "65535" "$(cat $MOUNT/gpio/gpio3/pwm_duty)"

echo "0"     > "$MOUNT/gpio/gpio3/pwm_duty"
check "pwm duty 0%"       "0"     "$(cat $MOUNT/gpio/gpio3/pwm_duty)"

# ----------------------------------------------------------------
# Test 5: ADC reads (GP26, floating)
# ----------------------------------------------------------------
info "Test 5: ADC reads (GP26, floating — checking format only)"

echo "adc" > "$MOUNT/gpio/gpio26/mode"

ADC_FAIL=0
for i in $(seq 1 5); do
    result="$(cat $MOUNT/gpio/gpio26/value)"
    raw=$(echo "$result" | awk '{print $1}')
    volts=$(echo "$result" | awk '{print $2}')
    TOTAL=$((TOTAL+1))
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 0 ] && [ "$raw" -le 4095 ]; then
        pass "ADC read $i: raw=$raw volts=$volts"
    else
        fail "ADC read $i: bad format or out of range — '$result'"
        ADC_FAIL=$((ADC_FAIL+1))
    fi
done

# ----------------------------------------------------------------
# Test 6: Error handling — ADC on non-ADC pin
# ----------------------------------------------------------------
info "Test 6: Error handling"

TOTAL=$((TOTAL+1))
if echo "adc" > "$MOUNT/gpio/gpio0/mode" 2>/dev/null; then
    fail "ADC on non-ADC pin should have been rejected"
else
    pass "ADC on non-ADC pin correctly rejected"
fi

# ----------------------------------------------------------------
# Test 7: Rapid pull toggle stress test
# ----------------------------------------------------------------
info "Test 7: Rapid pull toggle x$ITERATIONS"

echo "in" > "$MOUNT/gpio/gpio0/mode"
RAPID_FAIL=0

for i in $(seq 1 "$ITERATIONS"); do
    echo "up"   > "$MOUNT/gpio/gpio0/pull"
    val=$(cat "$MOUNT/gpio/gpio0/value")
    if [ "$val" != "1" ]; then
        RAPID_FAIL=$((RAPID_FAIL+1))
    fi

    echo "down" > "$MOUNT/gpio/gpio0/pull"
    val=$(cat "$MOUNT/gpio/gpio0/value")
    if [ "$val" != "0" ]; then
        RAPID_FAIL=$((RAPID_FAIL+1))
    fi

    # Progress every 10%
    if [ $((i % (ITERATIONS/10))) -eq 0 ]; then
        echo "  iteration $i/$ITERATIONS (failures so far: $RAPID_FAIL)"
    fi
done

TOTAL=$((TOTAL+1))
if [ "$RAPID_FAIL" -eq 0 ]; then
    pass "Rapid pull toggle: $((ITERATIONS*2)) reads, 0 failures"
else
    fail "Rapid pull toggle: $((ITERATIONS*2)) reads, $RAPID_FAIL failures"
fi

# ----------------------------------------------------------------
# Test 8: Rapid ADC reads
# ----------------------------------------------------------------
info "Test 8: Rapid ADC reads x$ITERATIONS"

echo "adc" > "$MOUNT/gpio/gpio26/mode"
ADC_RAPID_FAIL=0
START=$(date +%s%N)

for i in $(seq 1 "$ITERATIONS"); do
    result="$(cat $MOUNT/gpio/gpio26/value)"
    raw=$(echo "$result" | awk '{print $1}')
    if ! [[ "$raw" =~ ^[0-9]+$ ]] || [ "$raw" -gt 4095 ]; then
        ADC_RAPID_FAIL=$((ADC_RAPID_FAIL+1))
    fi

    if [ $((i % (ITERATIONS/10))) -eq 0 ]; then
        echo "  iteration $i/$ITERATIONS (failures so far: $ADC_RAPID_FAIL)"
    fi
done

END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
RATE=$(echo "scale=1; $ITERATIONS * 1000 / $ELAPSED" | bc)

TOTAL=$((TOTAL+1))
if [ "$ADC_RAPID_FAIL" -eq 0 ]; then
    pass "Rapid ADC: $ITERATIONS reads in ${ELAPSED}ms = ${RATE} reads/sec, 0 failures"
else
    fail "Rapid ADC: $ITERATIONS reads, $ADC_RAPID_FAIL failures"
fi

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
echo ""
echo "========================================"
echo " Results: $((TOTAL-FAILURES))/$TOTAL passed"
if [ "$FAILURES" -eq 0 ]; then
    echo -e " ${GREEN}ALL TESTS PASSED${NC}"
else
    echo -e " ${RED}$FAILURES TESTS FAILED${NC}"
fi
echo "========================================"

exit $FAILURES
