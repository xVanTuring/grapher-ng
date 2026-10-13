#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 工程是 xcodegen 生成的（project.yml 才是源），改完源文件或 project.yml 后先跑这个。
xcodegen generate

xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG \
    -configuration "${CONFIG:-Debug}" \
    -derivedDataPath build/DerivedData \
    build 2>&1 | grep -E "error:|warning:|BUILD " || true

echo "产物：build/DerivedData/Build/Products/${CONFIG:-Debug}/GrapherNG.app"
