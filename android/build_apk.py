"""Build a standalone Android APK that hosts the sanitized fitness-plan HTML."""

import glob
import os
import shutil
import subprocess
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SDK = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") or r"C:\Android\Sdk"
BT = os.path.join(SDK, "build-tools", "35.0.0")
JAVA_BIN = os.path.join(os.environ.get("JAVA_HOME") or r"C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot", "bin")
ANDROID_JAR = os.path.join(SDK, "platforms", "android-34", "android.jar")

ENV = os.environ.copy()
ENV["PATH"] = JAVA_BIN + os.pathsep + BT + os.pathsep + ENV.get("PATH", "")


def run(args, shell=False):
    print("RUN:", " ".join(str(a) for a in args), flush=True)
    result = subprocess.run(args, cwd=ROOT, env=ENV, shell=shell,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    print(result.stdout[-4000:], flush=True)
    if result.returncode != 0:
        raise SystemExit("build step failed: " + str(args))


def main():
    for d in ["gen", "classes", "dex"]:
        shutil.rmtree(os.path.join(ROOT, d), ignore_errors=True)
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)

    run([os.path.join(BT, "aapt2.exe"), "compile", "--dir", "res", "-o", "compiled.flata"])
    run([os.path.join(BT, "aapt2.exe"), "link",
         "-o", "base.apk",
         "-I", ANDROID_JAR,
         "--manifest", "AndroidManifest.xml",
         "-R", "compiled.flata",
         "-A", "assets",
         "--java", "gen",
         "--min-sdk-version", "21",
         "--target-sdk-version", "34",
         "--version-code", "3",
         "--version-name", "1.2",
         "--auto-add-overlay"])

    java_sources = glob.glob(os.path.join(ROOT, "src", "**", "*.java"), recursive=True)
    java_sources += glob.glob(os.path.join(ROOT, "gen", "**", "*.java"), recursive=True)
    run([os.path.join(JAVA_BIN, "javac.exe"), "--release", "8",
         "-cp", ANDROID_JAR, "-d", "classes"] + java_sources)

    class_files = glob.glob(os.path.join(ROOT, "classes", "**", "*.class"), recursive=True)
    run(["cmd", "/c", os.path.join(BT, "d8.bat"),
         "--lib", ANDROID_JAR, "--output", "dex"] + class_files)

    with zipfile.ZipFile(os.path.join(ROOT, "base.apk"), "a", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(ROOT, "dex", "classes.dex"), "classes.dex")

    run([os.path.join(BT, "zipalign.exe"), "-f", "4", "base.apk", "aligned.apk"])

    keystore = os.path.join(ROOT, "release.jks")
    if not os.path.exists(keystore):
        run([os.path.join(JAVA_BIN, "keytool.exe"), "-genkeypair",
             "-keystore", keystore, "-alias", "fitness",
             "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
             "-storepass", "fitness123", "-keypass", "fitness123",
             "-dname", "CN=Fitness Plan, OU=Personal, O=Personal, L=Unknown, ST=Unknown, C=CN"])

    out = os.path.join(ROOT, "fitness-plan-v1.2.apk")
    run(["cmd", "/c", os.path.join(BT, "apksigner.bat"), "sign",
         "--ks", keystore, "--ks-key-alias", "fitness",
         "--ks-pass", "pass:fitness123", "--key-pass", "pass:fitness123",
         "--out", out, "aligned.apk"])

    run(["cmd", "/c", os.path.join(BT, "apksigner.bat"), "verify", "--print-certs", out])
    print("APK ready:", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
