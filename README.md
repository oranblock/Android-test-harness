# Android Test Harness

Run **any** Android APK on an emulator from GitHub Actions, screenshot every
step, and get the run pushed to Telegram plus a timestamped archive.

Sibling of [ios-test-harness](https://github.com/oranblock/ios-test-harness),
built from the same session's findings — and cheaper and more capable, because
Android CI is simply a better environment than an iOS simulator.

```
.github/workflows/test-and-report.yml   emulator, install, run flow, archive, send
scripts/lib.sh                          tap, type_text, swipe, key, visit, record_clip…
flows/smoke.sh                          launch, background, resume, rotate — any app
flows/diagnose.sh                       start EVERY activity, prove each survives
flows/video.sh                          burst-capture frames: is it actually animating?
```

## Install as a Claude Code plugin

This repo is also a Claude Code plugin. It ships the `android-test-harness` skill, which
carries the hard-won CI facts — the failures that cost a round each — so Claude
drives these workflows correctly instead of rediscovering them.

```
/plugin marketplace add oranblock/Android-test-harness
/plugin install android-test-harness@android-test-harness
```

The skill loads on its own when you ask to test, screenshot or diagnose an app in
CI. `skills/android-test-harness/SKILL.md` is readable on its own if you would rather just read it.

## Why this beats the iOS harness

| | Android | iOS |
| :--- | :--- | :--- |
| runner cost | **ubuntu, 1×** | macOS, 10× on private repos |
| taps / typing / swipes | **work** (`adb shell input`) | idb will not install in CI |
| rotation | **works, when the activity allows it** (`rotate` reports UNCHANGED for an orientation-locked one) | not available |
| launch a specific screen | **`am start`**, any exported activity | only if the app reads a launch env var |
| crash detail | **full Java stack in logcat** | an abort with a native backtrace |
| GPU | swiftshader; most things render | Metal works, but **Filament cannot run at all** |

The one place iOS wins: nothing. Test Android here first.

## Run it

```sh
gh workflow run "Android Emulator Test & Report" --repo oranblock/Android-test-harness \
  -f apk_url=https://example.com/app-debug.apk \
  -f package=com.example.app \
  -f flow=diagnose \
  -f activities=".MainActivity .client.ForgeActivity .client.CargoActivity"
```

Or take the APK from another run's artifact (artifacts need auth, so a plain URL
cannot fetch them):

```sh
  -f artifact_run_id=<run id> -f package=com.example.app
```

Secrets, both optional: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`. With neither
set the run still works and the archive still attaches to the job.

## Finding your activities

```sh
adb shell dumpsys package com.example.app | grep -B2 -A2 "android.intent.action.MAIN"
# or, from the APK:
aapt dump badging app-debug.apk | grep launchable-activity
```

Only **exported** activities can be started with `am start`. The rest report
`Permission Denial`, which `diagnose` records as *skipped* rather than *failed* —
a manifest fact is not a bug.

## Writing a flow

```sh
source "$(dirname "$0")/../scripts/lib.sh"

launch "app_launched"
tap 540 1200 "tapped_build"
type_text "hello" "typed"
assert_running "survived"
```

| helper | does |
| :--- | :--- |
| `launch [name]` | cold start the launcher activity |
| `launch_activity <.Act> [name]` | start a specific screen — no coordinates |
| `visit <.Act> [name]` | launch it, record survival, keep going |
| `tap X Y name` / `swipe` / `type_text` / `key` | interaction |
| `back` / `home` | hardware keys |
| `send_step name [note]` | screenshot + logcat tail |
| `record_clip <secs> <name>` | frame burst, reports how many are unique |
| `assert_running [name]` | **fails the job** if the process died |
| `report_screens` | fails at the end, listing every screen that crashed |

## Lessons this harness was built with

Each of these cost a CI round on the iOS side. They are already fixed here.

- **`set +e` first** in any step that inspects its own failure. GitHub runs steps
  with `bash -e`, so `cmd > log; rc=$?` never reaches `rc`.
- **Never trust a recorder to finalise.** `screenrecord` writes an mp4 that is
  only valid if it stops cleanly; interrupted, you get media data with no `moov`
  atom — plausible size, reports success, plays nowhere. `record_clip` bursts
  screencaps instead, which have no finalisation step to get wrong.
- **Prove animation, don't assert it.** `record_clip` md5s every frame and prints
  how many are unique. 15/15 means it is moving; 1/15 means a stalled render.
- **Concurrency groups must include the inputs**, or one dispatch cancels
  another of the same app.
- **Artifacts need auth.** `gh run download`, never `curl`.
- **A tap that lands on nothing passes.** Prefer `am start`; treat taps as a
  bonus, never as navigation.

## Cost

`ubuntu-latest` is 1× — free on public repos, and the cheapest tier on private
ones. A `smoke` run is a few minutes including emulator boot. KVM is enabled in
the workflow; without it the emulator falls back to software rendering and
everything takes roughly ten times longer.
