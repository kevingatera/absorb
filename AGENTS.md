# AGENTS.md

Agent guidance for work in `/home/kevingatera/tmp-agents/absorb`.

## Goals

- Keep changes simple, maintainable, and compatible with older/newer Audiobookshelf server behavior.
- Prefer low-risk fixes over large rewrites.
- Avoid adding temporary/dev-only files to commits.

## Working rules

- Read `continuity.md` first before making changes.
- Update `continuity.md` after meaningful state changes (fixes, build status, release status, blockers).
- Follow existing commit style (`Fix ...`, `Add ...`, `Improve ...`, short subject line).
- Do not commit secrets or machine-local files.
- Keep `android/key.properties`, keystores, and signing material local only.

## Performance/debug workflow

- For startup/player slowdown reports, check server logs around the reported time first.
- Correlate app actions with `/personalized` timing and playback session start logs.
- Favor request dedupe/throttling and smaller payloads before deeper architectural changes.

## Android build/release workflow

- Use JDK 21 for Gradle/Flutter Android builds.
- Use local Android SDK at `/home/kevingatera/android-sdk` unless explicitly changed.
- Build command baseline:
  - `JAVA_HOME=/home/kevingatera/jdks/jdk-21.0.10+7 ANDROID_HOME=/home/kevingatera/android-sdk ANDROID_SDK_ROOT=/home/kevingatera/android-sdk flutter build apk --release`
- Signed release requires local `android/key.properties` plus a local keystore path.
- Keep release output naming consistent with project conventions.
- For homelab work, finish by creating a homelab release on the fork with a signed APK.
- GitHub Actions note: workflows are only runnable via `gh workflow run` when the workflow file exists on the repo default branch.

## Reusable commands

- Device and adb checks:
  - `"/home/kevingatera/android-sdk/platform-tools/adb" devices -l`
- Start paired app/server logging session:
  - `LOGDIR="/home/kevingatera/tmp-agents/absorb/data/generated/debug-logs"; TS=$(date +%Y%m%d-%H%M%S); APPLOG="$LOGDIR/app-$TS.log"; SRVLOG="$LOGDIR/server-$TS.log"; nohup "/home/kevingatera/android-sdk/platform-tools/adb" logcat -v time > "$APPLOG" 2>&1 & APPPID=$!; nohup ssh -o BatchMode=yes -o ConnectTimeout=10 root@192.168.1.108 "docker logs -f --since 30s audiobookshelf 2>&1" > "$SRVLOG" 2>&1 & SRVPID=$!; printf "ts=%s\napp_pid=%s\nserver_pid=%s\napp_log=%s\nserver_log=%s\n" "$TS" "$APPPID" "$SRVPID" "$APPLOG" "$SRVLOG" > "$LOGDIR/current-session.meta"`
- Stop active paired logging session:
  - `META="/home/kevingatera/tmp-agents/absorb/data/generated/debug-logs/current-session.meta"; APPPID=$(awk -F= '/^app_pid=/{print $2}' "$META"); SRVPID=$(awk -F= '/^server_pid=/{print $2}' "$META"); kill "$APPPID" "$SRVPID" 2>/dev/null || true`
- Focused app log scan for offline/absorbing states:
  - `grep -nE "\[Library\]|\[Absorbing\]|setNetworkOffline|setManualOffline|buildOfflineSections|loadPersonalizedView error|loadLibraries error" <app-log-path>`
- Signed release build:
  - `JAVA_HOME=/home/kevingatera/jdks/jdk-21.0.10+7 PATH=$JAVA_HOME/bin:$PATH ANDROID_HOME=/home/kevingatera/android-sdk ANDROID_SDK_ROOT=/home/kevingatera/android-sdk flutter build apk --release`
- Verify built APK identity/signature:
  - `"/home/kevingatera/android-sdk/build-tools/35.0.0/aapt" dump badging build/app/outputs/flutter-apk/app-release.apk | grep -E "^package:|application-label:"`
  - `"/home/kevingatera/android-sdk/build-tools/35.0.0/apksigner" verify --print-certs build/app/outputs/flutter-apk/app-release.apk`
- Create release notes without literal `\n`:
  - `gh release create <tag> <asset> --repo kevingatera/absorb --target homelab --title "<tag>" --notes "$(cat <<'EOF'`
  - `<multi-line notes here>`
  - `EOF` + `)"`
