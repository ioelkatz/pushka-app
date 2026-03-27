## Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

## Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

## Stripe
-keep class com.stripe.** { *; }
-dontwarn com.stripe.**
-keep class com.reactnativestripesdk.** { *; }
-dontwarn com.reactnativestripesdk.**

## Google Sign In
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

## Google Play Core (flutter deferred components — suppress missing class warnings)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

## Keep annotations
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
