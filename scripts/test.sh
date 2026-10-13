#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG \
    -configuration Debug \
    -derivedDataPath build/DerivedData \
    test 2>&1 | grep -E "error:|failed \(|passed \(|TEST " || true
