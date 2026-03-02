# Continuity (homelab-upstream)

## Session setup (2026-03-02)

- Created branch `homelab-upstream` from `upstream/main` (`538996f`).
- Branch tracking: `homelab-upstream...upstream/main`.
- Preserved existing uncommitted work by stashing tracked + untracked files:
  - `stash@{0}`: `On homelab: wip: pre-homelab-upstream setup 2026-03-02`

## Migration intent

- Re-apply homelab-specific commits from `homelab` onto `homelab-upstream` one commit at a time.
- For each candidate commit, verify whether upstream already includes equivalent behavior before cherry-picking.

## Candidate commit queue (from `upstream/main..homelab`)

- `fee7730` Fix personalized refresh overhead
- `47eb5c1` Add homelab side-by-side install support
- `876316a` Fix startup false offline detection
- `530e077` Fix offline toggle and absorbing empty state
- `f4bf283` Fix absorbing cache stack overflow
- `cced927` Add series-level download action
- `7a4c01d` Improve series download button UX
- `19613dc` Improve series download progress feedback
- `7a522ce` Queue series downloads immediately
- `c1aee30` Improve homelab APK size guidance
- `bda50e0` Fix release download notification failures
- `705e175` Improve tab-targeted refresh behavior
- `31046ca` Improve personalized include loading
- `5310d4c` Clean up API service analyzer warnings
- `f4b0da1` Improve startup refresh targeting
- `54c257b` Improve absorbing-first startup responsiveness

## Grouped workstreams (first-pass triage)

### Group A: Personalized/offline/startup behavior

- `fee7730` Fix personalized refresh overhead
- `876316a` Fix startup false offline detection
- `530e077` Fix offline toggle and absorbing empty state
- `f4bf283` Fix absorbing cache stack overflow
- `705e175` Improve tab-targeted refresh behavior
- `31046ca` Improve personalized include loading
- `5310d4c` Clean up API service analyzer warnings
- `f4b0da1` Improve startup refresh targeting
- `54c257b` Improve absorbing-first startup responsiveness

### Group B: Series download UX flow

- `cced927` Add series-level download action
- `7a4c01d` Improve series download button UX
- `19613dc` Improve series download progress feedback
- `7a522ce` Queue series downloads immediately

### Group C: Download pipeline robustness

- `bda50e0` Fix release download notification failures

### Group D: Homelab identity/side-by-side install

- `47eb5c1` Add homelab side-by-side install support

### Group E: Process/docs-only (non-port default)

- `c1aee30` Improve homelab APK size guidance
- `9841e3d` Add homelab agent continuity docs

## Notes

- Skipped continuity-only commits from the queue; this file is the continuity record for upstream merge work.
- Preferred port order: A -> C -> B -> D; keep E local unless explicitly needed on this branch.

## Migration matrix (2026-03-02 pass 1)

- `fee7730` -> `already present / partial`: fetch dedupe + cooldown behavior already exists upstream; no direct port needed.
- `876316a` -> `ported (adapted)`: startup no longer forces offline solely from `serverReachable=false`; keep background ping only.
- `530e077` -> `mostly present`: active-item offline visibility and manual-offline behavior already upstream; did not port debug-heavy logging parts.
- `f4bf283` -> `already present`: `_absorbingIdsAdd` recursion fix + network-only offline fallback behavior already upstream.
- `705e175` -> `ported (adapted)`: added `refreshProgressOnly()` and tab-targeted refresh path in `AppShell`.
- `31046ca` -> `ported (partial)`: `getPersonalizedView` now supports query shaping; provider + Android Auto now request lightweight includes/shelves.
- `5310d4c` -> `n/a`: analyzer-only cleanup not needed as standalone, small cleanup folded into current edits.
- `f4b0da1` -> `ported`: startup Android Auto refresh moved off critical path (`Future.microtask`), and AA continue fetch is targeted.
- `54c257b` -> `ported`: lazy tab instantiation in `AppShell`; Absorbing now shows blocking loader only for true startup-empty state.
- `bda50e0` -> `ported (adapted)`: added notification failure guards, queue safety against active overlap, and proguard generic-signature keep rules.
- `47eb5c1` -> `ported`: homelab side-by-side identity/scheme/authority changes re-applied on upstream base.
- `cced927` / `7a4c01d` / `19613dc` / `7a522ce` -> `partial`: retained upstream series UX baseline, added immediate queueing behavior (`waitForCompletion: false`) and title overflow guard.

## Series second-pass (2026-03-02)

- Re-diffed `lib/widgets/series_books_sheet.dart` against `upstream/main` and prior homelab series commits.
- Kept upstream's current series UX structure (no broad restyle).
- Added one extra net-positive UX delta from homelab:
  - Per-book live download percentage badge on each cover while actively downloading.
- Final retained series deltas now are:
  - Immediate queueing for "Download all" (`waitForCompletion: false`).
  - Long series title clamp (2 lines + ellipsis).
  - Per-book live download percentage badge during active download.

## Applied changes (files)

- Startup/offline/refresh: `lib/providers/library_provider.dart`, `lib/screens/app_shell.dart`, `lib/screens/absorbing_screen.dart`, `lib/main.dart`.
- Personalized API targeting: `lib/services/api_service.dart`, `lib/services/android_auto_service.dart`.
- Download robustness: `lib/services/download_service.dart`, `lib/services/download_notification_service.dart`, `android/app/proguard-rules.pro`.
- Homelab side-by-side identity: `android/app/build.gradle.kts`, `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/com/barnabas/absorb/CoverContentProvider.kt`, `lib/services/audio_player_service.dart`, `lib/services/android_auto_service.dart`, `lib/services/oidc_service.dart`.
- Series flow improvement retained: `lib/widgets/series_books_sheet.dart`.

## Validation

- Ran targeted analyze:
  - `flutter analyze lib/providers/library_provider.dart lib/services/api_service.dart lib/screens/app_shell.dart lib/screens/absorbing_screen.dart lib/main.dart lib/services/android_auto_service.dart lib/services/download_notification_service.dart lib/services/download_service.dart lib/widgets/series_books_sheet.dart lib/services/audio_player_service.dart lib/services/oidc_service.dart`
- Result: no analyzer errors in modified files (existing repo-level infos/warnings remain).

## Commit split (2026-03-02)

- `ac050be` Improve startup and targeted refresh behavior
- `a1a0226` Improve series download feedback and queueing
- `319dbf0` Fix download notification and queue resilience
- `982afae` Add homelab side-by-side app identity
- `8d9ced9` Update homelab-upstream migration continuity

## Release build prep (2026-03-02)

- Built release APK:
  - `JAVA_HOME=/home/kevingatera/jdks/jdk-21.0.10+7 PATH=$JAVA_HOME/bin:$PATH ANDROID_HOME=/home/kevingatera/android-sdk ANDROID_SDK_ROOT=/home/kevingatera/android-sdk flutter build apk --release --target-platform android-arm64`
- Output artifact:
  - `build/app/outputs/flutter-apk/app-release.apk`
  - release copy: `release-artifacts/absorb-v1.7.23-homelab-upstream.20260302-signed.apk`
- APK identity check (`aapt dump badging`):
  - package: `com.barnabas.absorb.homelab`
  - label: `Absorb Homelab`
  - version: `1.7.23 (34)`
- Signature check (`apksigner verify --print-certs`):
  - signer SHA-256: `142bbef4f332280ab7df20ec012bd1b4fb39ced8fe080c06b3acb923ffee5ccb`

## Release published (2026-03-02)

- GitHub release created from `homelab-upstream`:
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.23-homelab.20260302.1`
