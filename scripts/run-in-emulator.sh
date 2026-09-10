#!/usr/bin/env bash
# Everything the emulator step does, in ONE file.
#
# WHY A FILE AND NOT AN INLINE `script:` BLOCK.
#
# reactivecircus/android-emulator-runner does not hand your script to a shell.
# It splits it on newlines and runs each line as its own `/usr/bin/sh -c <line>`.
# Consequences, all observed in run 34531670258:
#
#   * variables do not survive between lines  -> `install_rc=$?` then
#     `echo "install rc=$install_rc"` printed `install rc=` (empty)
#   * `$?` refers to nothing                  -> return codes are unreadable
#   * a multi-line `if` is a syntax error     -> `sh: 1: Syntax error: end of
#     file unexpected (expecting "fi")`, which ENDED the run
#   * `exec >> file 2>&1` redirects a shell that exits on the same line, so the
#     artifact log came back 0 bytes
#
# The workflow therefore invokes exactly one line: this file. Its shebang gets
# us a real bash, with state, pipelines, `set -o pipefail` and multi-line
# constructs — none of which the inline form can have.
set +e   # this script inspects its own failure; -e would hide it

: "${PACKAGE:?}" "${REPORT_DIR:?}" "${FLOW:?}" "${APK:?}"

mkdir -p "${REPORT_DIR}/logs" "${REPORT_DIR}/screenshots"
# One process for the whole script, so this redirect holds for everything below.
# The step's stdout does not reach `gh run view --log`, so the artifact is the
# only channel that actually carries a failure out.
exec > >(tee -a "${REPORT_DIR}/logs/flow.txt") 2>&1

echo "=== device ==="
adb wait-for-device
echo "api level: $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
adb shell settings put global window_animation_scale 1.0

echo "=== install ==="
adb install -r -g "$APK"
install_rc=$?
echo "install rc=${install_rc}"

echo "=== third-party packages ==="
adb shell pm list packages -3 | tr -d '\r'

if ! adb shell pm list packages | tr -d '\r' | grep -qx "package:${PACKAGE}"; then
  echo "::error::'${PACKAGE}' is not installed — see the package list above"
  echo "hint: a debug build with applicationIdSuffix has a different id than the release one"
  exit 1
fi
echo "package present: ${PACKAGE}"

echo "=== flow: ${FLOW} ==="
adb logcat -c
chmod +x scripts/lib.sh "flows/${FLOW}.sh"
"./flows/${FLOW}.sh"
rc=$?
echo "=== flow rc=${rc} ==="

adb logcat -d > "${REPORT_DIR}/logs/full_logcat.txt" 2>/dev/null
exit "$rc"
