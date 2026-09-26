#!/usr/bin/env bash
# 幂等安装本地依赖：
#   - 后端：backend/.venv（解释器版本对不上、venv 损坏时自动重建；系统没有 pip/ensurepip
#     时回退到 get-pip.py 引导），再安装 requirements.txt
#   - 前端：frontend/node_modules（缺失或与当前平台不匹配时安装/修复）
# 重复执行安全：已装好的依赖会跳过。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
# shellcheck source=lib.sh
. scripts/lib.sh

VENV="$ROOT/backend/.venv"

# 判断现有 venv 是否能正常导入后端依赖。
venv_ok() {
  [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import fastapi, uvicorn, pydantic" >/dev/null 2>&1
}

bootstrap_backend() {
  if venv_ok; then
    ok "后端依赖已就绪，跳过安装"
    return 0
  fi

  if [ -e "$VENV" ] && [ ! -x "$VENV/bin/python" ]; then
    warn "发现损坏的 backend/.venv（解释器缺失，常见于 Python 版本对不上），将删除重建"
    rm -rf "$VENV"
  fi

  if [ ! -d "$VENV" ]; then
    log "创建后端虚拟环境 backend/.venv……"
    if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
      warn "python3 -m venv 不可用（系统缺 python3-venv/ensurepip），改用 --without-pip 创建后引导 pip"
      python3 -m venv --without-pip "$VENV"
      local get_pip
      get_pip=$(mktemp -t get-pip.XXXXXX.py)
      "$VENV/bin/python" - "$get_pip" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py", sys.argv[1])
PY
      "$VENV/bin/python" "$get_pip"
      rm -f "$get_pip"
    fi
  fi

  log "安装后端 Python 依赖（requirements.txt）……"
  "$VENV/bin/pip" install --upgrade pip >/dev/null
  "$VENV/bin/pip" install -r "$ROOT/backend/requirements.txt"

  venv_ok || die "后端依赖安装后自检失败（无法导入 fastapi/uvicorn），请查看上方 pip 输出"
  ok "后端依赖安装完成"
}

bootstrap_frontend() {
  # node_modules 可能是在别的平台装的（例如在 mac 上装完拷到 linux），
  # 此时目录存在但缺当前平台的原生可选依赖（@rollup/rollup-<platform>、
  # @esbuild/<platform>），vite build 会直接炸。用真实模块加载做自检。
  frontend_self_check() {
    (cd "$ROOT/frontend" && node -e "require('rollup'); require('esbuild')" >/dev/null 2>&1)
  }
  if [ -d "$ROOT/frontend/node_modules/vite" ] && frontend_self_check; then
    ok "前端依赖已就绪，跳过 npm install"
    return 0
  fi
  command -v npm >/dev/null 2>&1 || die "找不到 npm，无法安装前端依赖"
  if [ -d "$ROOT/frontend/node_modules" ]; then
    warn "frontend/node_modules 缺失或与当前平台不匹配（rollup/esbuild 原生依赖加载失败），开始修复"
  fi
  log "安装前端依赖（npm install）……"
  (cd "$ROOT/frontend" && npm install)
  # npm 对 optionalDependencies 有已知缺陷（npm/cli#4828），装完仍可能缺当前平台包，
  # 自检不过时按当前平台显式补装原生包。
  if ! frontend_self_check; then
    (cd "$ROOT/frontend" && node -e '
      const { execSync } = require("child_process");
      const p = process.platform, a = process.arch;
      const pkgs = [];
      if (p === "linux" && a === "arm64") pkgs.push("@rollup/rollup-linux-arm64-gnu", "@esbuild/linux-arm64");
      if (p === "linux" && a === "x64") pkgs.push("@rollup/rollup-linux-x64-gnu", "@esbuild/linux-x64");
      if (p === "darwin" && a === "arm64") pkgs.push("@rollup/rollup-darwin-arm64", "@esbuild/darwin-arm64");
      if (p === "darwin" && a === "x64") pkgs.push("@rollup/rollup-darwin-x64", "@esbuild/darwin-x64");
      if (pkgs.length) {
        console.warn("[setup] npm 漏装平台原生依赖，显式补装：" + pkgs.join(" "));
        execSync("npm install " + pkgs.join(" ") + " --no-save", { stdio: "inherit" });
      }')
  fi
  frontend_self_check || die "前端依赖自检失败（rollup/esbuild 无法加载），请删除 frontend/node_modules 后重跑 make setup"
  ok "前端依赖安装完成"
}

bootstrap_backend
bootstrap_frontend
ok "全部依赖就绪，可以执行 make up 一键拉起签发链路"
