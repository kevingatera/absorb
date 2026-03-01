# Continuity

## Current branch/status

- Branches: `homelab` (release), `homelab-automation` (workflow/docs) (fork: `kevingatera/absorb`, upstream: `pounat/absorb`).
- Slowdown fix committed as `fee7730` (`Fix personalized refresh overhead`).
- Agent docs committed as `9841e3d` (`Add homelab agent continuity docs`).
- Homelab side-by-side install support committed as `47eb5c1` (`Add homelab side-by-side install support`).

## Automation setup

- Added workflow: `.github/workflows/homelab-release.yml`.
- Workflow trigger: manual `workflow_dispatch`.
- Build job:
  - Restores signing key from GitHub secrets.
  - Builds signed release APK.
  - Uploads artifact for release job.
- Release job:
  - Uses environment `homelab-release`.
  - Requires manual reviewer approval before publish.
  - Creates or updates the GitHub release and uploads APK asset.

## GitHub environment/secrets

- Environment configured: `homelab-release`.
- Required reviewer configured: `kevingatera`.
- Allowed deployment branches configured: `homelab`, `homelab-automation`.
- Repository secrets set:
  - `HOMELAB_ANDROID_KEYSTORE_BASE64`
  - `HOMELAB_ANDROID_STORE_PASSWORD`
  - `HOMELAB_ANDROID_KEY_PASSWORD`
  - `HOMELAB_ANDROID_KEY_ALIAS`

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
  - release copy: `/home/kevingatera/tmp-agents/absorb/release-artifacts/absorb-v1.7.22-homelab.20260301.1-signed.apk`
- APK signature verification:
  - Cert DN: `CN=Absorb Homelab, OU=Homelab, O=Homelab, L=NA, ST=NA, C=US`
  - SHA-256: `142bbef4f332280ab7df20ec012bd1b4fb39ced8fe080c06b3acb923ffee5ccb`
- Homelab release published:
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301`
  - `https://github.com/kevingatera/absorb/releases/tag/v1.7.22-homelab.20260301.1` (side-by-side install build)

## Side-by-side install changes

- Android package id changed to `com.barnabas.absorb.homelab` so it installs alongside original Absorb.
- Launcher label changed to `Absorb Homelab` for easy visual distinction.
- Cover content provider authority now tracks app id (`${applicationId}.covers`) and uses homelab authority constants in app code.
- OIDC callback scheme changed to `audiobookshelfhomelab://oauth` to avoid callback conflicts when both apps are installed.

## Deployment docs

- Added: `docs/homelab-releases.md`
- README now links to deployment workflow docs.

## Open work

- None currently.
