# R8's rules for the shell: the activity, and what the native library calls and is called by.
-keep class dev.rocx.phone.** { *; }
-dontwarn org.jetbrains.annotations.**
# Names kept, so the APK's classes say what they are (the spike's evidence lists them).
-dontobfuscate
