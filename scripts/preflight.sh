#!/usr/bin/env bash
# 启动前检查：依赖（python3 / node / npm、后端 venv、前端 node_modules）与端口占用。
# 用法：scripts/preflight.sh [--require-deps]
#   默认模式：只检查外部命令与端口，缺依赖给修复建议；
#   --require-deps：额外要求两边依赖已安装，没装直接失败（供 dev-up 构建前使用）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
# shellcheck source=lib.sh
. scripts/lib.sh

REQUIRE_DEPS=0
[ "${1:-}" = "--require-deps" ] && REQUIRE_DEPS=1
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"

failures=0

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "    修复建议：$2"
    failures=$((failures + 1))
  else
    ok "找到命令：$1（$(command -v "$1")）"
  fi
}

log "检查必需命令……"
need_cmd python3 "请先安装 Python 3.10+（后端运行与联调脚本都依赖它）"
need_cmd node "请先安装 Node.js 18+（建议 20 LTS）"
need_cmd npm "随 Node.js 一起安装，请确认 npm 在 PATH 中"

log "检查端口占用（后端 ${BACKEND_PORT} / 前端 ${FRONTEND_PORT}）……"
for pair in "${BACKEND_PORT}:后端" "${FRONTEND_PORT}:前端"; do
  port="${pair%%:*}"; name="${pair##*:}"
  if ! port_is_free "$port"; then
    owner=$(port_owner "$port" || true)
    warn "${name}端口 ${port} 已被占用${owner:+，监听进程 pid=${owner}}"
    warn "  可执行「kill ${owner:-<占用进程>}」释放，或用 BACKEND_PORT/FRONTEND_PORT 指定其他端口"
    failures=$((failures + 1))
  else
    ok "端口 ${port} 空闲（${name}）"
  fi
done

if [ "$REQUIRE_DEPS" -eq 1 ]; then
  log "检查项目依赖是否已安装……"
  if [ -x "$ROOT/backend/.venv/bin/python" ] && "$ROOT/backend/.venv/bin/python" -c "import fastapi, uvicorn" >/dev/null 2>&1; then
    ok "后端虚拟环境与依赖就绪（backend/.venv）"
  else
    warn "后端依赖缺失或虚拟环境损坏（需要 fastapi/uvicorn）"
    echo "    修复建议：make setup"
    failures=$((failures + 1))
  fi
  if [ -d "$ROOT/frontend/node_modules/vite" ] && (cd "$ROOT/frontend" && node -e "require('rollup'); require('esbuild')" >/dev/null 2>&1); then
    ok "前端依赖就绪（frontend/node_modules）"
  else
    warn "前端依赖缺失或与当前平台不匹配（vite/rollup/esbuild 不可用，常见于 node_modules 是在别的操作系统上安装的）"
    echo "    修复建议：make setup"
    failures=$((failures + 1))
  fi
else
  log "跳过依赖安装检查（如需严格检查请加 --require-deps，或直接执行 make setup）"
fi

if [ "$failures" -gt 0 ]; then
  die "前置检查发现 ${failures} 个问题，按上面的修复建议处理后重试"
fi
ok "前置检查全部通过"
