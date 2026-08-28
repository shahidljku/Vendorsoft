# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }

# Google Play Core deferred components
-dontwarn com.google.android.play.core.**

# Razorpay
-keepattributes *Annotation*
-dontwarn com.razorpay.**
-keep class com.razorpay.** { *; }
-optimizations !method/inlining/
-keepclasseswithmembers class * {
  public void onPayment*(...);
}

# Preserve Icon Fonts and Resources
-keepclassmembers class * {
    ** MaterialIcons;
}
-dontwarn android.window.**

# VendorSoft app classes referenced by AndroidManifest (resolved by name at runtime)
-keep class com.vendorsoft.app.ImageSenderAccessibilityService { *; }
-keep class com.vendorsoft.app.CooldownAlarmReceiver { *; }
-keep class com.vendorsoft.app.BootReceiver { *; }
-keep class com.vendorsoft.app.MainActivity { *; }

