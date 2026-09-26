#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# venv 解释器缺失（常见于换机器、Python 大版本不一致）时自动重建，
# 缺 ensurepip 的精简 Python 走 get-pip.py 引导，避免新人克隆后第一道命令就失败。
if [ ! -x .venv/bin/python ]; then
  echo "[run.sh] 未找到可用的 .venv，正在创建……" >&2
  rm -rf .venv
  python3 -m venv .venv 2>/dev/null || {
    python3 -m venv --without-pip .venv
    tmp=$(mktemp -t get-pip.XXXXXX.py)
    python3 - "$tmp" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py", sys.argv[1])
PY
    .venv/bin/python "$tmp"; rm -f "$tmp"
  }
fi

.venv/bin/python -c "import fastapi, uvicorn" 2>/dev/null || {
  echo "[run.sh] 后端依赖缺失，正在安装 requirements.txt……" >&2
  .venv/bin/pip install -q -r requirements.txt
}

exec .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "${BACKEND_PORT:-8000}"
