#!/usr/bin/env bash
# 停止 dev-up.sh 拉起的前后端进程；服务没起时安静退出。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. scripts/lib.sh

RUN_DIR=".run"
stop_pid_file "$RUN_DIR/frontend.pid" "前端"
stop_pid_file "$RUN_DIR/backend.pid" "后端"

# 兜底：npm 会再派生一个 node（vite preview）子进程，按端口再清一次，
# 避免下次起来时端口仍被占用。这里的端口要与 dev-up.sh 实际绑定的一致，
# 不能用 FRONTEND_PORT 这类未导出的覆盖变量。
for pair in "8000:后端" "5173:前端"; do
  port="${pair%%:*}"; name="${pair##*:}"
  if ! port_is_free "$port"; then
    owner=$(port_owner "$port" || true)
    if [ -n "${owner:-}" ]; then
      warn "${name}端口 ${port} 仍被 pid ${owner} 占用，尝试结束"
      # 同端口可能有父子多个监听进程，按 pid 列表逐个结束。
      for pid in $owner; do
        kill "$pid" 2>/dev/null || true
      done
      sleep 1
      for pid in $owner; do
        kill -9 "$pid" 2>/dev/null || true
      done
    fi
  fi
done
ok "本地服务已全部停止"
