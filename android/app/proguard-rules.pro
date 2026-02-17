# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# just_audio
-keep class com.google.android.exoplayer2.** { *; }
-keep class androidx.media3.** { *; }

# audio_service
-keep class com.ryanheise.audioservice.** { *; }

# Google Play Core (not used but referenced by Flutter engine)
-dontwarn com.google.android.play.core.**

# Keep all annotations
-keepattributes *Annotation*

# Prevent stripping of native methods
-keepclasseswithmembernames class * {
    native <methods>;
}