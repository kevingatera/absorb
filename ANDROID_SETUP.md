# Absorb — Android App Name & APK Setup

## 1. App Display Name (what shows under the icon)

Edit `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:label="Absorb"
    ...
```

## 2. APK/Bundle Output Name

Edit `android/app/build.gradle` — add inside the `android { }` block:

```groovy
android {
    // ... existing config ...

    applicationVariants.all { variant ->
        variant.outputs.all {
            def versionName = variant.versionName
            outputFileName = "absorb-${versionName}.apk"
        }
    }
}
```

This will produce `absorb-1.0.0.apk` in `build/app/outputs/flutter-apk/`.

## 3. Version Number

The version is controlled in `pubspec.yaml`:

```yaml
version: 1.0.0+1
```

Format: `major.minor.patch+buildNumber`

When you want to bump it, change this line. For example `1.1.0+2`.

## 4. App Package Name (optional)

If you want to change the package from `com.example.audiobookshelf_app` to something like `com.absorb.app`:

1. In `android/app/build.gradle`, change `applicationId`:
   ```groovy
   defaultConfig {
       applicationId "com.absorb.app"
   }
   ```

2. Rename the directory structure under `android/app/src/main/java/` to match

Or use the `change_app_package_name` Flutter package for an automated rename.

## 5. Download Notification Permissions

Add these to your `android/app/src/main/AndroidManifest.xml` inside the `<manifest>` tag (before `<application>`):

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
```

This enables the persistent download progress notification that keeps downloads alive when the app is backgrounded or the screen is locked.

After adding the dependency, run:
```bash
flutter pub get
```
