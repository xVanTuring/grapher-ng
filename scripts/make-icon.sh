#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 重新生成 AppIcon.appiconset（asset catalog，Apple Silicon 上二进制的图标来源）。
# 需要带 Pillow 的 Python：优先用约定的科学计算 venv，否则退回系统 python3。
PYTHON="${PYTHON:-$HOME/.agents/_internal/_tmp/.venv/bin/python}"
if [ ! -x "$PYTHON" ]; then
    PYTHON="$(command -v python3)"
fi

"$PYTHON" scripts/make-icon.py
