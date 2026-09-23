#!/usr/bin/env bash
#
# test_macos_recovery_usb.sh
# Automated regression and safety test suite for macos_recovery_usb.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/macos_recovery_usb.sh"

GREEN="\033[1;32m"
RED="\033[1;31m"
RESET="\033[0m"

log_pass() {
    echo -e "${GREEN}[PASS]${RESET} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${RESET} $1"
    exit 1
}

echo "=================================================="
echo " Running Automated Test Suite for macOS USB Tool"
echo "=================================================="

# Test 1: Bash Syntax Check
echo -n "Test 1: Bash syntax check... "
if bash -n "$TARGET_SCRIPT"; then
    log_pass "Bash syntax valid"
else
    log_fail "Bash syntax error"
fi

# Test 2: Zsh Syntax Check
echo -n "Test 2: Zsh syntax check... "
if zsh -n "$TARGET_SCRIPT"; then
    log_pass "Zsh syntax valid"
else
    log_fail "Zsh syntax error"
fi

# Test 3: Help Flag
echo -n "Test 3: Help message flag (--help)... "
if "$TARGET_SCRIPT" --help | grep -q "Safety Guarantee"; then
    log_pass "--help output verified"
else
    log_fail "--help output missing expected text"
fi

# Test 4: Internal Disk Failsafe (disk0)
echo -n "Test 4: Fail-safe rejection of internal hardware (disk0)... "
set +e
output_disk0=$("$TARGET_SCRIPT" --disk disk0 2>&1)
exit_code_disk0=$?
set -e
if [[ $exit_code_disk0 -ne 0 ]] && echo "$output_disk0" | grep -q "INTERNAL hardware storage"; then
    log_pass "disk0 correctly and strictly rejected"
else
    log_fail "Safety failsafe failed to block disk0!"
fi

# Test 5: Root Filesystem Failsafe (disk3)
echo -n "Test 5: Fail-safe rejection of root system filesystem... "
set +e
output_disk3=$("$TARGET_SCRIPT" --disk disk3 2>&1)
exit_code_disk3=$?
set -e
if [[ $exit_code_disk3 -ne 0 ]] && echo "$output_disk3" | grep -q "FAIL-SAFE TRIGGERED"; then
    log_pass "Root container correctly and strictly rejected"
else
    log_fail "Safety failsafe failed to block root container!"
fi

# Test 6: Verification on existing USB drive if present
if [[ -d "/Volumes/Install macOS Sequoia" ]]; then
    echo -n "Test 6: Data integrity verification on /Volumes/Install macOS Sequoia... "
    if "$TARGET_SCRIPT" --verify "/Volumes/Install macOS Sequoia" | grep -q "INTEGRITY VERIFICATION RESULT: PASS"; then
        log_pass "Cryptographic and data integrity verification passed"
    else
        log_fail "Integrity verification failed on known valid volume"
    fi
else
    echo "Test 6: Skipping live USB verification (volume not mounted)"
fi

echo "=================================================="
echo -e "${GREEN}All tests passed successfully!${RESET}"
echo "=================================================="
