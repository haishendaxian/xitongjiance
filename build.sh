#!/bin/bash
# 编译并安装「系统监测」到 /Applications
set -e
cd "$(dirname "$0")"
APP="/Applications/系统监测.app"
EXE="系统监测"
swiftc -O -framework Cocoa -o "$EXE" 系统监测.swift
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.xitongjiance.plist 2>/dev/null || launchctl unload ~/Library/LaunchAgents/com.local.xitongjiance.plist 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/$EXE" 2>/dev/null || true
sleep 1
cp "$EXE" "$APP/Contents/MacOS/$EXE"
codesign --force --deep --sign - "$APP"
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.xitongjiance.plist 2>/dev/null || launchctl load ~/Library/LaunchAgents/com.local.xitongjiance.plist
echo "已安装并启动：$APP"
