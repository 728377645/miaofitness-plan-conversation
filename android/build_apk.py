"""Build a standalone Android APK that hosts the fitness app HTML.

跨平台（Windows / macOS / Linux）。依赖 Android SDK 的 build-tools、platform android-34
和 JDK 17+（推荐 21）。构建产物为 build/miaomiao-fitness.apk，文件名不带版本号。

用法：
    python android/build_apk.py

环境变量：
    ANDROID_SDK_ROOT / ANDROID_HOME   Android SDK 路径
    ANDROID_BUILD_TOOLS               默认 35.0.0
    ANDROID_PLATFORM                  默认 android-34
    JAVA_HOME                         JDK 路径（不设则用 PATH 中的 java）
"""

import glob
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
WIN = os.name == "nt"

SDK = (
    os.environ.get("ANDROID_SDK_ROOT")
    or os.environ.get("ANDROID_HOME")
    or (r"C:\Android\Sdk" if WIN else os.path.expanduser("~/Android/Sdk"))
)
BUILD_TOOLS_VERSION = os.environ.get("ANDROID_BUILD_TOOLS", "35.0.0")
BT = os.path.join(SDK, "build-tools", BUILD_TOOLS_VERSION)
PLATFORM = os.environ.get("ANDROID_PLATFORM", "android-34")
ANDROID_JAR = os.path.join(SDK, "platforms", PLATFORM, "android.jar")

KEYSTORE = os.path.join(ROOT, "release.p12")
KEY_ALIAS = "miaomiao"
KEY_PASS = "miaomiao123"
OUT_APK = os.path.join(ROOT, "build", "miaomiao-fitness.apk")
APP_HTML = os.path.join(REPO, "ios", "FitnessPlan", "Resources", "index.html")
ASSETS_HTML = os.path.join(ROOT, "assets", "index.html")

ENV = os.environ.copy()


def _java_bin():
    """返回 JDK 的 bin 目录；未设置 JAVA_HOME 时从 PATH 里的 javac 反推。"""
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        return os.path.join(java_home, "bin")
    javac = shutil.which("javac")
    return os.path.dirname(javac) if javac else ""


JAVA_BIN = _java_bin()
for extra in (JAVA_BIN, BT):
    if extra:
        ENV["PATH"] = extra + os.pathsep + ENV.get("PATH", "")


def tool(name):
    """按平台补可执行后缀：Windows 用 .exe / .bat。"""
    if not WIN:
        return os.path.join(BT, name)
    for suffix in (".exe", ".bat"):
        candidate = os.path.join(BT, name + suffix)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(BT, name + ".exe")


def run(args):
    print("RUN:", " ".join(str(a) for a in args), flush=True)
    result = subprocess.run(
        args, cwd=ROOT, env=ENV,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace",
    )
    print(result.stdout[-4000:], flush=True)
    if result.returncode != 0:
        raise SystemExit("build step failed: " + " ".join(str(a) for a in args))


def sync_assets():
    """以 ios 内嵌页面为唯一源，避免仓库里维护多份相同 HTML。"""
    if not os.path.exists(APP_HTML):
        raise SystemExit("找不到页面源文件: " + APP_HTML)
    os.makedirs(os.path.dirname(ASSETS_HTML), exist_ok=True)
    src = open(APP_HTML, "rb").read()
    if not os.path.exists(ASSETS_HTML) or open(ASSETS_HTML, "rb").read() != src:
        with open(ASSETS_HTML, "wb") as f:
            f.write(src)
        print("已同步页面: ios/FitnessPlan/Resources/index.html -> android/assets/index.html")


def main():
    if not os.path.exists(ANDROID_JAR):
        raise SystemExit("找不到 android.jar，请检查 ANDROID_SDK_ROOT 与 ANDROID_PLATFORM: " + ANDROID_JAR)
    if not os.path.isdir(BT):
        raise SystemExit("找不到 build-tools，请检查 ANDROID_BUILD_TOOLS: " + BT)

    sync_assets()

    for d in ["gen", "classes", "dex", "build"]:
        shutil.rmtree(os.path.join(ROOT, d), ignore_errors=True)
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)

    run([tool("aapt2"), "compile", "--dir", "res", "-o", "compiled.flata"])
    run([tool("aapt2"), "link",
         "-o", "base.apk",
         "-I", ANDROID_JAR,
         "--manifest", "AndroidManifest.xml",
         "-R", "compiled.flata",
         "-A", "assets",
         "--java", "gen",
         "--min-sdk-version", "21",
         "--target-sdk-version", "34",
         "--version-code", "4",
         "--version-name", "1.0",
         "--auto-add-overlay"])

    java_sources = glob.glob(os.path.join(ROOT, "src", "**", "*.java"), recursive=True)
    java_sources += glob.glob(os.path.join(ROOT, "gen", "**", "*.java"), recursive=True)
    run([os.path.join(JAVA_BIN, "javac"), "--release", "8",
         "-cp", ANDROID_JAR, "-d", "classes"] + java_sources)

    class_files = glob.glob(os.path.join(ROOT, "classes", "**", "*.class"), recursive=True)
    run([tool("d8"), "--lib", ANDROID_JAR, "--output", "dex"] + class_files)

    with zipfile.ZipFile(os.path.join(ROOT, "base.apk"), "a", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(ROOT, "dex", "classes.dex"), "classes.dex")

    run([tool("zipalign"), "-f", "4", "base.apk", "aligned.apk"])

    if not os.path.exists(KEYSTORE):
        raise SystemExit("缺少签名库 android/release.p12（用于保证各次构建签名一致）")

    os.makedirs(os.path.dirname(OUT_APK), exist_ok=True)
    run([tool("apksigner"), "sign",
         "--ks", KEYSTORE, "--ks-key-alias", KEY_ALIAS,
         "--ks-pass", "pass:" + KEY_PASS, "--key-pass", "pass:" + KEY_PASS,
         "--out", OUT_APK, "aligned.apk"])

    run([tool("apksigner"), "verify", "--print-certs", OUT_APK])
    print("APK ready:", OUT_APK, os.path.getsize(OUT_APK), "bytes")


if __name__ == "__main__":
    main()
