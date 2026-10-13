#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 构建并直接运行 App，日志输出到终端（同 FreeMind / Perch 的做法）。
xcodegen generate
xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG \
    -configuration Debug \
    -derivedDataPath build/DerivedData \
    build 2>&1 | grep -E "error:|BUILD " || true

exec "build/DerivedData/Build/Products/Debug/GrapherNG.app/Contents/MacOS/GrapherNG" "$@"
