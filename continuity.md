# Continuity

## Current branch/status

- Branch: `homelab` (fork: `kevingatera/absorb`, upstream: `pounat/absorb`).
- Slowdown fix committed as `fee7730` (`Fix personalized refresh overhead`).
- Agent docs committed as `9841e3d` (`Add homelab agent continuity docs`).
- Homelab side-by-side install support committed as `47eb5c1` (`Add homelab side-by-side install support`).

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
- APK signature verification:
  - Cert DN: `CN=Absorb Homelab, OU=Homelab, O=Homelab, L=NA, ST=NA, C=US`
  - SHA-256: `142bbef4f332280ab7df20ec012bd1b4fb39ced8fe080c06b3acb923ffee5ccb`
- Homelab release published:
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301`

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

## Open work

- None currently.
