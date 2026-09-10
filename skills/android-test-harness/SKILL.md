---
name: android-test-harness
description: Build and RUN an Android app on an emulator in GitHub Actions — compile a private Kotlin/KMP project on free Linux runners, install the APK, tap through it, screenshot every step, and report to Telegram, a GitHub issue, or a secret gist. Use when asked to test an Android app in CI, get screenshots or video of an Android app, diagnose which screens crash, or when no device is available. Repo: oranblock/Android-test-harness.
---

## What this is

`github.com/oranblock/Android-test-harness` — a public repo with two workflows
that build any Android project and drive the resulting APK on an emulator.

```
Build Android Debug APK        private source -> .apk artifact -> issue + Telegram
Android Emulator Test & Report that artifact  -> install, launch, tap, screenshot -> Telegram
```

The sibling of `ios-test-harness`, and the cheap one. Linux runners bill at 1x
against macOS's 10x, so a full Android sweep costs a tenth of the equivalent iOS
one — and unlike iOS CI, **taps actually work**: `adb shell input` is part of the
platform, with no `idb`, no Homebrew tap, and no companion process.

**Public repo, private source, on purpose.** The source is checked out with a
token and never published. Compiler output goes to a file, then to Telegram and
a secret gist; only the error COUNT and FILE NAMES reach the public issue.

**A debug APK is deliberate.** It needs no keystore, so no signing secret ever
comes near this repo, and it is exactly what the emulator wants.

## Running it

```sh
# 1. compile (produces an artifact)
gh workflow run "Build Android Debug APK" --repo oranblock/Android-test-harness \
  -f source_repo=owner/repo -f ref=branch -f gradle_task=:app:assembleDebug

# 2. run it (takes the artifact from that run id)
gh workflow run "Android Emulator Test & Report" --repo oranblock/Android-test-harness \
  -f artifact_run_id=<build run id> -f package=com.example.app.debug \
  -f flow=smoke -f api_level=34
```

Secrets: `SOURCE_REPO_TOKEN` (read a private repo), `TELEGRAM_BOT_TOKEN` +
`TELEGRAM_CHAT_ID` (optional), `GIST_TOKEN` (optional, classic PAT with `gist`).

## Flows

| flow | does |
| :--- | :--- |
| `smoke` | launch, prove alive, background, resume, rotate — knows nothing about the app |
| `diagnose` | launch EVERY activity named in `activities`, prove each survives, screenshot each |
| `video` | burst-capture frames, hash them, stitch with ffmpeg |

Helpers in `scripts/lib.sh`: `launch`, `launch_activity`, `visit`, `tap`,
`type_text`, `swipe`, `key`, `back`, `home`, `rotate`, `send_step`,
`record_clip`, `pid_of`, `assert_running`, `report_screens`.

---

# Hard-won facts

Everything below cost a CI round. Read before debugging.

## The emulator action runs each LINE as its own shell

This is the big one, and it is not documented anywhere obvious.
`reactivecircus/android-emulator-runner` does **not** hand `script:` to a shell.
It splits it on newlines and runs `/usr/bin/sh -c <line>`, once per line.

| written inline | actually |
| :--- | :--- |
| `cmd` then `rc=$?` on the next line | `$?` refers to nothing; `rc` is empty |
| `exec >> log 2>&1` | redirects a shell that exits on that same line; the log is 0 bytes |
| a multi-line `if ... fi` | `sh: 1: Syntax error: end of file unexpected (expecting "fi")`, run over |
| `exec > >(tee ...)` | dash has no process substitution: `Syntax error: redirection unexpected` |

That is also `sh`, not bash, so nothing inline may use `[[ ]]`, arrays or
`${var/a/b}` either.

**Fix: make `script:` exactly one line invoking a checked-in file.** Its shebang
gets a real bash, with state, pipefail and multi-line constructs. Put the
explanation in that file's header, not in the YAML, or someone inlines it again.

Cost three rounds, the last two returning an empty report with no way to see
why — the line added to make failures visible was itself the failure.

## A flow script must NOT run under `set -e`

A flow gathers evidence, and every probe in it runs a command that legitimately
returns non-zero: `pidof` on a dead process, `grep` with no match. Under `-e` any
of those ends the sweep **before it can photograph what it was sent to look at**.

Observed: a run reported failure after one screenshot while the app was healthy —
`MainActivity` started, `libEGL_emulation.so` loaded, native libraries loaded,
Choreographer drawing frames, no `FATAL EXCEPTION` anywhere. The harness had
killed its own flow.

Use `set -uo pipefail`. Signal failure explicitly: `assert_running` returns 1,
flows end with `report_screens`, the workflow propagates the flow's exit code.

## Liveness: `pidof` is not enough

`pidof` matches the process NAME, so an app renamed by `android:process=` or
truncated to 15 characters can be alive and invisible to it. Fall back to
`ps -A | grep -F " $PACKAGE"`. When the assertion really does fail, dump
`dumpsys activity activities | grep mResumedActivity` — that is what
distinguishes a probe bug from a crash, and the probe bug is the likelier one.

## `applicationIdSuffix` changes the package id

A debug build with `applicationIdSuffix = ".debug"` installs as
`com.example.app.debug`. Pass the release id and `am start` silently starts
nothing, `pidof` finds nothing, and the only evidence is a screenshot of the
launcher — which reads exactly like a crash on launch.

**Always print `adb shell pm list packages -3` and assert the package is present
before running the flow.** It is two seconds and it names the mistake.

## Rotation is a request, not a result

`settings put system user_rotation 1` does nothing to an activity declaring
`android:screenOrientation="portrait"` or `"sensorPortrait"`. The sweep then
files two identical screenshots under the names "landscape" and "portrait" and
passes, having tested nothing. One run produced four byte-identical 1080x2400
PNGs across steps 6 to 9.

Compare `adb shell wm size` before and after and report which happened. Same rule
as frame hashing: a screenshot that looks right is not evidence.

## Drive screens by activity, not by blind taps

Android's answer to the iOS launch-env trick, and a better one: any **exported**
activity starts directly with `adb shell am start -n pkg/.Activity`. No
coordinates, no menu walking, and a screen that crashes names itself instead of
taking the sweep with it.

A non-exported activity fails with `Permission Denial` — a manifest fact, not a
crash — so report it as skipped, never as broken.

Taps are available here and worth using, but they remain the fragile option: a
tap that lands on nothing produces a screenshot of the PREVIOUS screen and a
green run, which is the worst failure mode available.

## Video: capture frames, not screenrecord

`adb shell screenrecord` writes to the DEVICE and finalises its mp4 only when
stopped cleanly. Interrupt it wrong and you pull back a file with media data and
no `moov` atom — plausible size, reports success, plays nowhere. The iOS harness
lost three CI rounds to exactly that with `simctl recordVideo`.

Screencaps have no finalisation step, so the worst case is fewer frames rather
than a corrupt file that claims to be fine. `record_clip` bursts `CLIP_FPS`
(default 5) per second and stitches with ffmpeg, which **does** exist on the
Linux runner images, unlike macOS.

**Proving animation:** `md5sum` every frame. All-unique means the scene really is
animating; identical hashes mean a stalled render. If you produce an mp4
anywhere, check it with `grep -qa moov file.mp4`. A file size proves a file
exists, not that it opens.

## Runner gotchas

- **Enable KVM** with a udev rule, or the emulator falls back to software
  rendering and a four-minute sweep takes forty.
- **`gh run download` creates a DIRECTORY** named after the artifact with the
  file inside. `find -name '*.apk'` then matches the directory and adb fails with
  `copy_to_file: ...apk: Is a directory`. Use `find -type f`.
- **Artifacts need auth.** `curl` on the UI link returns HTML. Use
  `gh run download`, which also keeps the binary private.
- **Concurrency groups must include the inputs.** A group keyed only on workflow
  name means one dispatch silently CANCELS another of the same app — and
  comparing configurations is often the entire point.
- **`bash -e` on ordinary steps.** GitHub runs every `run:` with it, so
  `cmd > log 2>&1; rc=$?` exits before `rc` is captured. Put `set +e` first in
  any step that inspects its own failure.
- **Skipped frames on the emulator** (`Choreographer: Skipped 230 frames!`) are a
  software-GPU artifact, not a signal about the app.

## Telegram

A bot token from @BotFather is static — no OTP, no session, no login. That is the
*client* API (MTProto), a different thing. A bot cannot start a conversation, so
message it once with `/start` or every send fails 403. `TELEGRAM_CHAT_ID` is
numeric, negative for groups.

## Keeping private source out of a public repo

- build steps redirect to a FILE, never stdout (compiler errors quote source)
- the public issue carries status, counts and FILE NAMES only
- full logs go to Telegram and a secret gist
- **`gh gist create` has NO `--secret` flag.** Gists are secret by default and
  `--public` opts out. Passing `--secret` prints usage and exits 1, which looks
  like an auth failure and is not.
- report gist/Telegram failures explicitly — a silent redaction step is worse
  than none, because nobody can tell it is broken

## Read the screenshots

They answer questions no log does, and a green run hides them. From the first
passing Skirmish sweep: the app never left its first-run language picker, its
title was clipped under the status bar (a missing top inset — the same bug the
iOS sweep showed), and the process id changed across backgrounding, meaning the
app was killed and cold-started rather than resumed. The run was green.

Download with `gh run download`, unzip, and actually look.

---

# Known blockers

| blocker | status |
| :--- | :--- |
| **Orientation-locked activities cannot be rotation-tested** | Manifest fact. `rotate` reports UNCHANGED rather than pretending. |
| **Emulator GPU is swiftshader** | Frame timings are meaningless. Render *correctness* is testable, performance is not. |
| **Artifacts are public on a public repo** | Keep APKs as artifacts (auth-gated download), never release assets. |

## Compared with iOS

| | Android | iOS |
| :--- | :--- | :--- |
| runner cost | 1x Linux | 10x macOS |
| taps/typing/swipes | yes, `adb shell input` | no, Homebrew refuses the idb tap |
| ffmpeg on runner | yes | no |
| GPU | swiftshader, correctness only | paravirtualised Metal, real |
| hard limit | none found yet | Filament cannot run on ANY simulator |

See the `ios-test-harness` skill for the Apple side.
