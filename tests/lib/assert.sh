#!/usr/bin/env bash
# Assertion helpers for the paseo-container smoke suite.
# Source this file; do not execute it.

set -euo pipefail

ASSERT_PASSED=0
ASSERT_FAILED=0

_pass() {
    ASSERT_PASSED=$((ASSERT_PASSED + 1))
    printf '  ok   %s\n' "$1"
}

_fail() {
    ASSERT_FAILED=$((ASSERT_FAILED + 1))
    printf '  FAIL %s\n' "$1" >&2
    if [ $# -gt 1 ]; then
        printf '       %s\n' "$2" >&2
    fi
}

fail() {
    _fail "$1" "${2:-}"
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$name"
    else
        _fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [ -z "$needle" ]; then
        _fail "$name" "empty needle: the assertion cannot fail"
        return
    fi
    # Match in the shell, not with `printf | grep -q`: grep -q exits on the
    # first match, and once the haystack outgrows the pipe buffer (Paseo's
    # logs do), printf dies of SIGPIPE and pipefail turns the match into a
    # failure.
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$name"
    else
        _fail "$name" "expected output to contain '$needle', got '$haystack'"
    fi
}

assert_ok() {
    local name="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        _pass "$name"
    else
        _fail "$name" "command failed: $* => $output"
    fi
}

assert_fail() {
    local name="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        _fail "$name" "command unexpectedly succeeded: $* => $output"
    else
        _pass "$name"
    fi
}

summary() {
    printf '\n%d passed, %d failed\n' "$ASSERT_PASSED" "$ASSERT_FAILED"
    [ "$ASSERT_FAILED" -eq 0 ]
}
