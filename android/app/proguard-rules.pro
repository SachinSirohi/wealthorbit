# flutter_local_notifications uses Gson reflection for scheduled notifications.
-keep class com.dexterous.** { *; }
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Flutter deferred-components stubs reference Play Core which is not bundled.
-dontwarn com.google.android.play.core.**

# Keep Drift/sqlite3 native bridge classes.
-keep class org.sqlite.** { *; }
-keep class eu.simonbinder.** { *; }
