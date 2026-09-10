#!/usr/bin/env bash
# Shared helpers for Android flow scripts. Source this, don't run it:
#
#   source "$(dirname "$0")/../scripts/lib.sh"
#
# Provided by the workflow: PACKAGE, REPORT_DIR, TELEGRAM_* (optional).
#
# Everything here is `adb`, which matters: unlike the iOS harness, taps really
# work on Android CI. There is no third-party tool to install and no companion
# process to connect — `adb shell input` is part of the platform.

# NOT -e. A flow is an evidence-gathering script, and every probe in it runs a
# command that legitimately returns non-zero — `pidof` on a dead process, `grep`
# with no match. Under -e any of those ends the sweep before it can photograph
# what went wrong, which is exactly what happened in run 34532362398: the app
# had launched and was drawing frames, and the harness reported a failure with
# one screenshot and no reason.
#
# Failure is signalled explicitly instead: assert_running returns 1, flows end
# with `report_screens`, and the workflow propagates the flow's exit code.
set -uo pipefail

: "${PACKAGE:?PACKAGE not set — run this from the workflow}"
: "${REPORT_DIR:?REPORT_DIR not set}"

STEP_N=0
FAILED_SCREENS=""
LAST_START_OUT=""

# --- internals ---------------------------------------------------------------

_tg_enabled() { [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; }
_html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# --- evidence ----------------------------------------------------------------

# send_step <name> [note] — screenshot + logcat tail, no interaction
send_step() {
  local name="$1" note="${2:-}"
  STEP_N=$((STEP_N + 1))
  local label
  label=$(printf '%02d_%s' "$STEP_N" "$name")
  local shot="${REPORT_DIR}/screenshots/${label}.png"
  local snip="${REPORT_DIR}/logs/${label}.txt"

  adb exec-out screencap -p > "$shot" 2>/dev/null || { echo "  ! screenshot failed at ${label}"; return 0; }
  adb logcat -d -t 40 2>/dev/null > "$snip" || echo "(no logcat)" > "$snip"

  echo "  → ${label}${note:+ — $note}"
  _tg_enabled || return 0
  local body
  body=$(grep -iE "fatal|exception|error" "$snip" | tail -4 | _html_escape)
  [ -n "$body" ] || body=$(tail -3 "$snip" | _html_escape)
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
    -F chat_id="${TELEGRAM_CHAT_ID}" \
    -F photo="@${shot}" \
    -F caption="📸 <b>${label}</b> $(date +%H:%M:%S)${note:+%0A${note}}%0A<code>${body}</code>" \
    -F parse_mode="HTML" -o /dev/null || echo "  ! telegram send failed (continuing)"
}

# --- interaction (works on Android, unlike iOS CI) ---------------------------

tap()       { echo "tap ($1,$2)"; adb shell input tap "$1" "$2"; sleep "${TAP_SETTLE:-1}"; send_step "$3"; }
type_text() { adb shell input text "${1// /%s}"; sleep 1; send_step "$2"; }
swipe()     { adb shell input swipe "$1" "$2" "$3" "$4" "${SWIPE_MS:-300}"; sleep 1; send_step "$5"; }
key()       { adb shell input keyevent "$1"; sleep 1; send_step "$2"; }
back()      { key KEYCODE_BACK "${1:-back}"; }
home()      { key KEYCODE_HOME "${1:-home}"; }

# --- lifecycle ---------------------------------------------------------------

terminate() { adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true; }

# launch [name] — cold start the launcher activity
launch() {
  terminate; sleep 1
  adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep "${LAUNCH_SETTLE:-6}"
  send_step "${1:-launched}"
}

# launch_activity <.Activity|pkg/component> [name]
#
# Android's answer to a launch-env variable, and a better one: any EXPORTED
# activity starts directly. No coordinates, no menu walking, and a screen that
# crashes names itself instead of taking the sweep with it.
#
# A non-exported activity fails with "Permission Denial" — a manifest fact, not a
# crash — so visit() reports it as skipped rather than broken.
launch_activity() {
  local act="$1" name="${2:-$1}"
  local comp="$act"
  case "$act" in */*) ;; *) comp="${PACKAGE}/${act}" ;; esac
  terminate; sleep 1
  LAST_START_OUT=$(adb shell am start -n "$comp" 2>&1 | tr -d '\r')
  sleep "${SCREEN_SETTLE:-5}"
  send_step "$name"
}

# pid_of — echoes the app's pid, or nothing. Never fails.
#
# `pidof` exits 1 when the process is absent, which is information, not an
# error. `ps -A` is the fallback: pidof matches the process NAME, and a process
# renamed by android:process= or truncated to 15 chars can hide from it.
pid_of() {
  local pid
  pid=$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r')
  if [ -z "$pid" ]; then
    pid=$(adb shell ps -A 2>/dev/null | tr -d '\r' | grep -F " $PACKAGE" | awk '{print $2}' | head -1)
  fi
  echo "$pid"
}

# assert_running [name] — the cheapest true assertion: is the process alive?
assert_running() {
  local pid
  pid=$(pid_of)
  if [ -n "$pid" ]; then
    send_step "${1:-still_running}" "process alive (pid $pid)"
    return 0
  fi
  send_step "${1:-CRASHED}" "⚠️ process is GONE"
  echo "::error::$PACKAGE is not running after step ${STEP_N}"
  # Say what the device saw, so a probe bug is distinguishable from a crash.
  echo "--- top-of-stack ---"
  adb shell dumpsys activity activities 2>/dev/null | grep -m3 -i "mResumedActivity\|topResumedActivity" | tr -d '\r'
  return 1
}

# visit <activity> [name] — launch a screen, record whether it survived, continue
visit() {
  local act="$1" name="${2:-$1}"
  launch_activity "$act" "$name"
  case "$LAST_START_OUT" in
    *"Permission Denial"*|*"does not exist"*)
      echo "     skipped: $name (not exported)"; return 0 ;;
  esac
  if [ -n "$(pid_of)" ]; then
    echo "     ok: $name"
  else
    echo "     CRASHED: $name"
    FAILED_SCREENS="$FAILED_SCREENS $name"
    # Android gives a real stack, unlike a simulator abort. Keep it.
    adb logcat -d -t 300 2>/dev/null | grep -A25 "FATAL EXCEPTION" \
      > "${REPORT_DIR}/logs/CRASH_${name}.txt" 2>/dev/null || true
  fi
}

report_screens() {
  if [ -n "$FAILED_SCREENS" ]; then
    echo "::error::screens that did not survive launch:$FAILED_SCREENS"
    return 1
  fi
  echo "all screens survived launch"
}

# rotate <0|1> [name] — request an orientation and REPORT WHETHER IT HAPPENED.
#
# Setting user_rotation is a request, not a result. An activity declaring
# android:screenOrientation="sensorPortrait" (every screen in Skirmish except
# the battle) ignores it completely, and the sweep then files two identical
# screenshots under the names "landscape" and "portrait" — a green run that
# proves nothing. So compare the reported size and say which it was.
rotate() {
  local want="$1" name="${2:-rotation}"
  local before after
  before=$(adb shell wm size 2>/dev/null | tr -d '\r' | tail -1)
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation "$want"
  sleep "${ROTATE_SETTLE:-3}"
  after=$(adb shell wm size 2>/dev/null | tr -d '\r' | tail -1)
  if [ "$before" = "$after" ]; then
    send_step "$name" "orientation UNCHANGED ($after) — activity is probably orientation-locked"
  else
    send_step "$name" "rotated: $before -> $after"
  fi
}

# --- motion ------------------------------------------------------------------

# record_clip <seconds> <name> — burst of screencaps, not screenrecord.
#
# `adb shell screenrecord` writes to the DEVICE and finalises its mp4 only when
# stopped cleanly; interrupt it wrong and you pull back a file with media data
# and no moov atom — plausible size, reports success, plays nowhere. The iOS
# harness lost three CI rounds to exactly that with simctl's recordVideo.
#
# Screencaps have no finalisation step. Worst case is fewer frames, never a
# corrupt file that claims to be fine.
record_clip() {
  local secs="${1:-3}" name="${2:-clip}"
  local frames="${REPORT_DIR}/.frames_${name}"
  local fps="${CLIP_FPS:-5}"
  local total=$(( secs * fps ))
  mkdir -p "$frames"
  echo "  ● capturing ${total} frames over ${secs}s"
  local i=0
  while [ "$i" -lt "$total" ]; do
    adb exec-out screencap -p > "$(printf '%s/f%04d.png' "$frames" "$i")" 2>/dev/null || true
    i=$((i + 1))
  done
  local got
  got=$(ls "$frames"/*.png 2>/dev/null | wc -l | tr -d ' ')
  echo "  ● captured ${got} frames"
  [ "$got" -gt 1 ] || { echo "  ! too few frames"; return 0; }

  # Unique hashes are the PROOF of animation. Identical frames mean a stalled
  # render or a static image, and "it looks animated" is not evidence.
  local uniq
  uniq=$(md5sum "$frames"/*.png 2>/dev/null | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
  if [ "$uniq" -gt 1 ]; then
    echo "  ● ${uniq}/${got} frames unique — animating"
  else
    echo "  ● ${uniq}/${got} frames unique — STATIC"
  fi

  local out="${REPORT_DIR}/${name}.mp4"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -framerate "$fps" -pattern_type glob -i "$frames/*.png" \
      -c:v libx264 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
      "$out" >/dev/null 2>&1 || true
  fi

  if [ -s "$out" ] && grep -qa moov "$out" 2>/dev/null; then
    echo "  ● $(du -h "$out" | cut -f1) mp4 — finalised"
    _tg_enabled && curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVideo" \
      -F chat_id="${TELEGRAM_CHAT_ID}" -F video="@${out}" \
      -F caption="🎥 ${name} · ${uniq}/${got} unique frames" -o /dev/null || true
  else
    echo "  ! no playable mp4 — sending frames"
    local n=0
    for f in "$frames"/*.png; do
      n=$((n + 1)); [ $((n % 3)) -eq 1 ] || continue
      _tg_enabled && curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
        -F chat_id="${TELEGRAM_CHAT_ID}" -F photo="@${f}" \
        -F caption="🎞 ${name} ${n}/${got}" -o /dev/null || true
    done
  fi
  # Evidence, not an assertion: never fail a flow over a recording.
  return 0
}

# A flow that dies should still leave evidence.
trap 'rc=$?; if [ $rc -ne 0 ]; then send_step "FAILURE_final_frame" "exit $rc"; fi; exit $rc' EXIT
