# Continuity

## Current branch/status

- Branch: `homelab` (fork: `kevingatera/absorb`, upstream: `pounat/absorb`).
- Slowdown fix committed as `fee7730` (`Fix personalized refresh overhead`).
- Agent docs committed as `9841e3d` (`Add homelab agent continuity docs`).
- Homelab side-by-side install support committed as `47eb5c1` (`Add homelab side-by-side install support`).
- False offline startup fallback committed as `876316a` (`Fix startup false offline detection`).
- Offline toggle + absorbing empty-state stability committed as `530e077` (`Fix offline toggle and absorbing empty state`).

## Series download enhancement (2026-03-01)

- Added "download whole series" action in the top-right of the series books bottom sheet.
- File: `lib/widgets/series_books_sheet.dart`
  - New top-right header action queues all non-downloaded books in the series.
  - Uses existing `DownloadService` queueing semantics.
  - Shows contextual snackbars (`queued`, `already downloaded`, or first error).
  - Displays reactive button state via `ListenableBuilder(DownloadService())`.

## Series download UX follow-up (2026-03-01)

- Refined series header action to better match existing app download controls.
- Handles long series names by limiting header title to 2 lines with ellipsis.
- Added per-book live download percentage badge in the same top-right thumbnail position used by the done badge.
- Series list now listens to `DownloadService` updates so item progress badges update without reopening the sheet.
- Series "Download all" now queues all eligible books immediately instead of waiting for each full download to complete.
- Added download diagnostics logs for queue flow:
  - `[Series] Queueing whole series...`
  - `[Download] Request/Queueing/Dequeued/Execute start/...`

## Download stuck diagnosis (2026-03-01)

- Reproduced with paired app/server logs and observed real download flow events.
- Root cause from app logs:
  - `PlatformException ... TypeToken must be created with a type argument ... When using code shrinkers ... preserve generic signatures`
  - Stack traces originated from `flutter_local_notifications` cancel path.
- Impact:
  - Notification plugin exceptions were bubbling into download pipeline and marking downloads as failed/stuck.
  - Queue processor could also start while another item was actively downloading, allowing overlapping execution.
- Fixes applied:
  - `lib/services/download_service.dart`
    - Prevent queue processor from starting while an active download is running.
    - Wait for active download to clear before processing queued items.
    - Treat notification failures as non-fatal (start/progress/complete/error/dismiss guarded).
  - `lib/services/download_notification_service.dart`
    - Guard notification cancel calls against plugin exceptions.
  - `android/app/proguard-rules.pro`
    - Preserve generic signatures for shrinked release builds (`-keepattributes Signature`).
    - Add keep rules for `flutter_local_notifications`/Gson TypeToken patterns.

## Build status (2026-03-01)

- `flutter analyze lib/widgets/series_books_sheet.dart`: passed.
- Built signed release APK:
  - `/home/kevingatera/tmp-agents/absorb/build/app/outputs/flutter-apk/app-release.apk`
- Verified package/signature:
  - package: `com.barnabas.absorb.homelab`
  - label: `Absorb Homelab`
  - signer SHA-256: `142bbef4f332280ab7df20ec012bd1b4fb39ced8fe080c06b3acb923ffee5ccb`

## APK size analysis (2026-03-01)

- Large APK root cause:
  - Fat APK packaging pulls multiple native runtime blobs (Flutter engine + app libs) across ABIs.
  - Biggest entries were `libflutter.so` and `libapp.so` (x86_64, arm64, armeabi-v7a).
  - Main Java/Kotlin dex footprint (`classes.dex`) is significant but secondary versus native libs.
- Measured baseline (multi-ABI release command):
  - Build time: ~97s
  - APK size: ~62 MB
- Measured size-optimized homelab command:
  - `flutter build apk --release --target-platform android-arm64`
  - Build time: ~85s (faster)
  - APK size: ~24-25 MB (much smaller)
- Quality/functionality impact:
  - No media quality reduction or feature removal.
  - Runtime behavior on arm64 phones remains unchanged.
  - This is now the preferred homelab release build mode.

## Release/build process notes

- Why no GitHub build was visible:
  - Fork default branch is `main`, but homelab workflow was only on non-default branch.
  - `gh workflow run` and Actions workflow listing only work for workflows present on default branch.
- Why some release notes showed literal `\n`:
  - Release notes were passed as a quoted single-line string with escaped newline sequences.
  - GitHub stored the backslash characters literally instead of rendering new lines.
  - Use HEREDOC-based `--notes` input to preserve real newlines.

## Live debug finding (2026-03-01)

- During live test, app logs showed: `loadPersonalizedView error: Stack Overflow` followed by forced offline transition.
- Root cause was a recursion bug in `lib/providers/library_provider.dart`:
  - `_absorbingIdsAdd` called itself instead of appending when no `afterKey` insert point existed.
- Impact:
  - Threw during personalized load/cache update.
  - Catch path treated it as network error and switched app to offline mode.
  - Home + Absorbing were affected (offline sections), while Library could still appear online.
- Fix:
  - `_absorbingIdsAdd` now does `_absorbingBookIds.add(key)` for normal append.
  - Offline fallback now only triggers on likely network exceptions (socket/timeout/http/handshake), not all exceptions.
  - Added reasoned offline state logs and richer absorbing build logs for future debugging.

## Findings captured

- Reported slowdown was tied to expensive server home shelf generation, not playback session start.
- During the incident window, server logs showed personalized shelf loads up to ~21s with repeated parallel loads.
- Absorb was doing heavier/duplicated work on refresh paths versus upstream app behavior.

## Fix implemented

- `lib/services/api_service.dart`
  - `getPersonalizedView` now supports lightweight query params (`minified`, `include`, optional `shelves`, `limit`).
  - Handles list/map response shapes safely.
- `lib/providers/library_provider.dart`
  - Added simple in-flight dedupe + short cooldown for personalized fetches.
  - Removed duplicate progress fetch from `loadPersonalizedView` path.
  - Changed refresh ordering to avoid concurrent duplicate calls.
  - Kept explicit `force` refresh on direct user actions.

## Validation status

- `flutter pub get`: passed.
- Focused analyze on changed files: no errors (only pre-existing warnings/info).
- Full tests: no `test/` directory in this repo.

## Build/release notes

- Flutter installed at `/home/kevingatera/.local/share/flutter`.
- Binaries linked in `/home/kevingatera/.local/bin/flutter` and `/home/kevingatera/.local/bin/dart`.
- Android release build requires:
  - JDK 21 (`/home/kevingatera/jdks/jdk-21.0.10+7`)
  - Android SDK (`/home/kevingatera/android-sdk`)
  - Local signing config (`android/key.properties` + local keystore)
- Local homelab signing material created:
  - Keystore: `/home/kevingatera/.keystores/absorb/absorb-homelab.jks`
  - Signing env: `/home/kevingatera/.keystores/absorb/homelab-signing.env`
  - Local key properties: `/home/kevingatera/tmp-agents/absorb/android/key.properties`
- Signed APK build artifact:
  - `/home/kevingatera/tmp-agents/absorb/build/app/outputs/flutter-apk/app-release.apk`
  - release copy: `/home/kevingatera/tmp-agents/absorb/release-artifacts/absorb-v1.7.22-homelab.20260301-signed.apk`
  - release copy: `/home/kevingatera/tmp-agents/absorb/release-artifacts/absorb-v1.7.22-homelab.20260301.6-signed.apk`
- APK signature verification:
  - Cert DN: `CN=Absorb Homelab, OU=Homelab, O=Homelab, L=NA, ST=NA, C=US`
  - SHA-256: `142bbef4f332280ab7df20ec012bd1b4fb39ced8fe080c06b3acb923ffee5ccb`
- Homelab release published:
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.1`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.2`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.3`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.4`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.5`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.6`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.7`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.8` (size-optimized arm64 APK)
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.9` (download stall fixes)

## Side-by-side install changes

- Android package id changed to `com.barnabas.absorb.homelab` so it installs alongside original Absorb.
- Launcher label changed to `Absorb Homelab` for easy visual distinction.
- Cover content provider authority now tracks app id (`${applicationId}.covers`) and uses homelab authority constants in app code.
- OIDC callback scheme changed to `audiobookshelfhomelab://oauth` to avoid callback conflicts when both apps are installed.

## Offline detection follow-up

- Investigated false offline state in homelab build (home showing downloaded-only sections while server was reachable).
- Root cause: startup logic trusted `/ping` probe as authoritative and forced `_networkOffline = true`, which can be wrong behind some reverse proxies.
- Fix applied in `lib/providers/library_provider.dart`:
  - startup no longer forces offline only because `auth.serverReachable` is false
  - keeps background ping retries but proceeds with normal API loading
  - resets transient `_networkOffline` on auth update and lets real API calls decide offline state
- Validation: `flutter analyze lib/providers/library_provider.dart` passed.

## Offline toggle + absorbing follow-up

- Reproduced with adb + server logs under `data/generated/debug-logs/`.
- Observed manual offline toggle race/stale state:
  - `setManualOffline(false)` was followed by immediate offline section rebuild in logs.
  - Server logs showed successful API cache hits at the same time.
- Root cause:
  - Manual toggle back to online still depended on stale `_networkOffline` state.
  - Absorbing offline filter could hide the currently active item and show empty state.
- Fixes in `lib/providers/library_provider.dart`:
  - Manual offline OFF now clears stale `_networkOffline` when device connectivity exists, then refreshes/syncs.
  - Added reasoned offline transition logging (`setNetworkOffline(..., reason: ...)`) and richer state logs.
  - Connectivity/ping/load failure paths now log source/reason consistently.
- Fixes in `lib/screens/absorbing_screen.dart`:
  - Offline filter now preserves the active playing/casting item.
  - Added throttled absorbing build-state logs for troubleshooting.
- Validation:
  - `flutter analyze lib/providers/library_provider.dart lib/screens/absorbing_screen.dart` (no errors; existing deprecation infos only).

## Open work

- None currently.
