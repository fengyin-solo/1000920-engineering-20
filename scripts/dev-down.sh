#!/usr/bin/env bash
# 停止 dev-up.sh 拉起的本地联调服务（按进程组回收，避免残留 vite/uvicorn 子进程）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT_DIR/.run"
BACKEND_PID="$RUN_DIR/backend.pid"
FRONTEND_PID="$RUN_DIR/frontend.pid"

if [ -t 1 ]; then GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'; else GREEN=""; YELLOW=""; RESET=""; fi

stop_one() {
  local label="$1" pidfile="$2"
  if [ ! -f "$pidfile" ]; then
    printf '%s\n' "${YELLOW}[SKIP]${RESET} 未找到 ${label} pid 文件，${label}可能未启动"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "${YELLOW}[SKIP]${RESET} ${label}进程（PID ${pid:-未知}）已不在"
    rm -f "$pidfile"
    return 0
  fi
  # 负 PID 表示向整个进程组发信号；普通启动（无 setsid）时退回单进程停止。
  if kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; then
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    printf '%s\n' "${GREEN}[OK]${RESET} ${label}已停止（PID $pid）"
  else
    printf '%s\n' "${YELLOW}[WARN]${RESET} 无法停止 ${label}（PID $pid），请手工 kill"
  fi
  rm -f "$pidfile"
}

stop_one "前端" "$FRONTEND_PID"
stop_one "后端" "$BACKEND_PID"

# 兜底：如果还有漏网的 uvicorn / vite preview，按命令行特征提示（不擅自 kill 非本脚本启动的进程）。
leftovers=""
command -v ss >/dev/null 2>&1 && leftovers="$(ss -ltnp 2>/dev/null | grep -E ':(8000|5173)\b' || true)"
if [ -n "$leftovers" ]; then
  printf '%s\n' "${YELLOW}[WARN]${RESET} 8000/5173 端口仍有监听，可能是手工启动的服务："
  printf '%s\n' "$leftovers"
fi
