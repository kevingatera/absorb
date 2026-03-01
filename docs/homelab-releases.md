# Homelab Releases

This repo supports signed Android release builds for the homelab fork, including manual approval before publishing a GitHub release.

## Branches

- `homelab`: release branch for installable homelab app builds.
- `homelab-automation`: automation/workflow updates.

## App identity for side-by-side install

Homelab builds use a separate package identity so they can be installed alongside upstream Absorb:

- Application ID: `com.barnabas.absorb.homelab`
- App label: `Absorb Homelab`
- OIDC callback scheme: `audiobookshelfhomelab://oauth`

## Required GitHub secrets

Set these repository secrets in `kevingatera/absorb`:

- `HOMELAB_ANDROID_KEYSTORE_BASE64`
- `HOMELAB_ANDROID_STORE_PASSWORD`
- `HOMELAB_ANDROID_KEY_PASSWORD`
- `HOMELAB_ANDROID_KEY_ALIAS`

`HOMELAB_ANDROID_KEYSTORE_BASE64` should be the base64-encoded bytes of the `.jks` file.

## Manual approval gate

Workflow release publishing uses the `homelab-release` environment.

- Configure required reviewers for this environment (already set for `kevingatera`).
- Only approved runs can publish releases.

## Workflow

Workflow file: `.github/workflows/homelab-release.yml`

Trigger via `workflow_dispatch` with:

- `tag` (required), e.g. `v1.7.22-homelab.20260301.2`
- `release_name` (optional)
- `release_notes` (optional)
- `run_analyze` (optional, default `false`)

Flow:

1. Build job restores keystore from secrets and generates signed release APK.
2. APK artifact is uploaded as `homelab-signed-apk`.
3. Release job waits on `homelab-release` approval.
4. After approval, GitHub release is created/updated and APK is attached.

## Manual local fallback

If CI is unavailable, local signed release build still works:

```bash
JAVA_HOME=/home/kevingatera/jdks/jdk-21.0.10+7 \
ANDROID_HOME=/home/kevingatera/android-sdk \
ANDROID_SDK_ROOT=/home/kevingatera/android-sdk \
flutter build apk --release
```

Signing is read from `android/key.properties` (local only, never committed).
