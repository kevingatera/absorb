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
