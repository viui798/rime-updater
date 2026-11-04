#!/usr/bin/env python3
"""把更新器打包成可双击运行的软件。

macOS：生成 dist/RimeUpdater.app（内含脚本与界面，无需安装依赖）
Windows：生成 dist/启动更新器.bat

    python3 build_app.py
"""

import platform
import shutil
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
APP_NAME = "RimeUpdater"
SOURCES = ("update_desktop.py", "gui_app.py")


def copy_sources(dest):
    dest.mkdir(parents=True, exist_ok=True)
    for name in SOURCES:
        shutil.copy2(ROOT / name, dest / name)
    web_dest = dest / "web"
    if web_dest.exists():
        shutil.rmtree(web_dest)
    shutil.copytree(ROOT / "web", web_dest)


INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>芝士虎整更新器</string>
  <key>CFBundleDisplayName</key><string>芝士虎整更新器</string>
  <key>CFBundleIdentifier</key><string>com.viui798.rime-updater</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>{exe}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict>
</plist>
"""

LAUNCHER = """#!/bin/bash
APP_DIR="$(cd "$(dirname "$0")/../Resources/app" && pwd)"
LOG="$HOME/Library/Logs/CheeseTigerUpdater.log"
mkdir -p "$(dirname "$LOG")"

for candidate in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [ -x "$candidate" ]; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  osascript -e 'display dialog "找不到 python3，请先安装 Python 3。" buttons {"好"} with icon stop'
  exit 1
fi

exec "$PY" "$APP_DIR/gui_app.py" --port 8765 >>"$LOG" 2>&1
"""


def build_macos():
    app = DIST / f"{APP_NAME}.app"
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents" / "MacOS"
    resources = app / "Contents" / "Resources" / "app"
    macos.mkdir(parents=True)
    copy_sources(resources)
    (app / "Contents" / "Info.plist").write_text(
        INFO_PLIST.format(exe=APP_NAME), encoding="utf-8")

    launcher = macos / APP_NAME
    launcher.write_text(LAUNCHER, encoding="utf-8")
    launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"已生成 {app}")
    print("双击即可使用；首次打开如被拦截，右键选择「打开」。")


def build_windows():
    launch_dir = DIST / "芝士虎整更新器"
    if launch_dir.exists():
        shutil.rmtree(launch_dir)
    copy_sources(launch_dir)
    bat = DIST / "启动更新器.bat"
    bat.write_text(
        "@echo off\r\n"
        "chcp 65001 >nul\r\n"
        "cd /d \"%~dp0芝士虎整更新器\"\r\n"
        "start \"\" pythonw gui_app.py\r\n"
        "if errorlevel 1 start \"\" python gui_app.py\r\n",
        encoding="utf-8")
    print(f"已生成 {launch_dir} 与 {bat}")


def main():
    DIST.mkdir(exist_ok=True)
    system = platform.system()
    if system == "Darwin":
        build_macos()
    elif system == "Windows":
        build_windows()
    else:
        copy_sources(DIST / "芝士虎整更新器")
        print(f"已复制到 {DIST / '芝士虎整更新器'}，运行 python3 gui_app.py 启动")


if __name__ == "__main__":
    sys.exit(main())
