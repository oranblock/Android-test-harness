#!/usr/bin/env bash
# Full screen sweep: start every activity named in ACTIVITIES, prove each
# survives, photograph it, and keep a real stack for any that dies.
#
# WHY NOT TAPS. Android taps do work — but a tap that lands on nothing produces
# a screenshot of the PREVIOUS screen and a passing run, which is the worst
# outcome available. `am start` names the screen exactly and cannot miss.
#
# Only EXPORTED activities can be started this way; the rest report
# "Permission Denial" and are reported as skipped, not failed. That distinction
# matters: a manifest fact is not a bug.
#
#   -f activities=".MainActivity .client.ForgeActivity .client.CargoActivity"
source "$(dirname "$0")/../scripts/lib.sh"

echo "== screen sweep: $PACKAGE =="

if [ -z "${ACTIVITIES:-}" ]; then
  echo "no ACTIVITIES given — falling back to the launcher activity only"
  launch "launcher"
  assert_running "launcher_alive"
  echo "Tip: list exported activities with"
  echo "  adb shell dumpsys package $PACKAGE | grep -A2 'android.intent.action.MAIN'"
  exit 0
fi

for act in $ACTIVITIES; do
  visit "$act" "$(echo "$act" | tr -d '.' | tr '/' '_')"
done

report_screens
echo "== sweep complete =="
