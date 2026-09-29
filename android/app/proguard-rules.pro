# ---------------------------------------------------------------------------
#  R8 / ProGuard rules for the release build.
#
#  The debug build (the one the APK workflow produces) does not run R8 at all, but
#  the release build does, and JNI is exactly the case where over-shrinking turns
#  into a crash on the device rather than a build error. So the engine's Java half
#  is kept explicitly instead of trusting it to survive.
# ---------------------------------------------------------------------------

# The AAR ships `-keep class hev.htproxy.** { *; }` in its own proguard.txt, which
# the Android Gradle plugin consumes. Repeating it here is deliberate: this is the
# class whose native methods `System.loadLibrary("hev-socks5-tunnel")` binds to, and
# a release build that strips it fails at runtime with UnsatisfiedLinkError.
-keep class hev.htproxy.** { *; }

# Belt and braces for the JNI boundary: any class holding a native method must keep
# both the method names and the names of its parameters' types.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# The engine reads its YAML by path, so the config constant must not be inlined away
# in a way that changes the file name it writes. Keeping the holder is harmless.
-keep class io.github.kylosonic.proxytunnel.core.HevConfig { *; }

# kotlinx.coroutines and Compose ship their own consumer rules; these two silence
# warnings for optional references that R8 cannot resolve in an app-only build.
-dontwarn org.jetbrains.annotations.**
-dontwarn kotlinx.coroutines.debug.**

# Keep line numbers so a stack trace from a sideloaded build is still readable,
# but rename the source file so nothing about the project layout leaks.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
