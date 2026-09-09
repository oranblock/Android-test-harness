#!/usr/bin/env bash
# Default flow. Knows nothing about the app, so it works on day one: launch it,
# prove it stays up, background and restore it, look for a crash.
#
# A low bar deliberately — "does not launch" and "dies on resume" are invisible
# to a build that merely compiles, and both are caught here.
source "$(dirname "$0")/../scripts/lib.sh"

echo "== smoke: $PACKAGE =="

launch "cold_launch"
assert_running "after_launch"

sleep 3
send_step "settled"

# Background/foreground is where state-restoration bugs surface.
home "backgrounded"
sleep 2
launch "resumed"
assert_running "after_resume"

# Rotation shakes out layout crashes. On Android this actually runs, unlike iOS CI.
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 1
sleep 3
send_step "landscape"
adb shell settings put system user_rotation 0
sleep 3
send_step "portrait"

assert_running "final"
echo "== smoke complete =="
