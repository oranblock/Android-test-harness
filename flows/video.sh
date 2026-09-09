#!/usr/bin/env bash
# Film the app. A screenshot proves a screen drew once; only a burst shows
# whether anything is actually animating — and unique frame hashes prove it
# rather than asserting it.
source "$(dirname "$0")/../scripts/lib.sh"

echo "== video: $PACKAGE =="

if [ -n "${ACTIVITIES:-}" ]; then
  set -- $ACTIVITIES
  launch_activity "$1" "before_clip"
else
  launch "before_clip"
fi

sleep 2   # let any particle system reach steady state
record_clip "${CLIP_SECONDS:-3}" "clip"
assert_running "after_recording"

echo "== video complete =="
