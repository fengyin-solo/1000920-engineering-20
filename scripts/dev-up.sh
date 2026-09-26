#!/usr/bin/env bash
# 一键拉起签发链路本地联调环境：
#   1. 前置检查（命令、端口 8000/5173、依赖是否就绪）
#   2. 构建前端（npm run build；可用 --no-build 跳过）
#   3. 分别后台拉起后端 uvicorn 与前端 vite preview（构建产物 + /api 代理）
#   4. 等两个服务健康
#   5. 调接口写入一份 待编制→待审核→待签发→已签发 的示例报告（幂等，可重跑）
#   6. 跑可复现检查：报告结论与接口返回（含经前端代理）一致
# 全部通过后服务保持运行，Ctrl-C 或 make down 停止。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
# shellcheck source=lib.sh
. scripts/lib.sh

BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
FRONTEND_URL="http://127.0.0.1:${FRONTEND_PORT}"
RUN_DIR="$ROOT/.run"
LOG_DIR="$RUN_DIR/logs"
BACKEND_PID="$RUN_DIR/backend.pid"
FRONTEND_PID="$RUN_DIR/frontend.pid"
FLOW_OUT="$RUN_DIR/report-issued.json"
DO_BUILD=1

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数：$arg" ;;
  esac
done

mkdir -p "$LOG_DIR"

cleanup() {
  echo
  log "收到中断，正在停止本地服务……"
  stop_pid_file "$FRONTEND_PID" "前端"
  stop_pid_file "$BACKEND_PID" "后端"
  exit 130
}
trap cleanup INT TERM

log "== 第 1 步：前置检查 =="
scripts/preflight.sh --require-deps

if [ "$DO_BUILD" -eq 1 ]; then
  log "== 第 2 步：构建前端 =="
  (cd "$ROOT/frontend" && npm run build) 2>&1 | tee "$LOG_DIR/frontend-build.log"
  ok "前端构建完成（frontend/dist）"
else
  warn "已跳过前端构建（--no-build），直接使用现有 frontend/dist 或 dev server"
fi

log "== 第 3 步：启动后端（:${BACKEND_PORT}）与前端（:${FRONTEND_PORT}） =="
(
  cd "$ROOT/backend"
  nohup .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$BACKEND_PORT" \
    </dev/null >"$LOG_DIR/backend.log" 2>&1 &
  echo $! >"$BACKEND_PID"
)
export VITE_PROXY_TARGET="$BACKEND_URL"
(
  cd "$ROOT/frontend"
  nohup npm run preview -- --port "$FRONTEND_PORT" --strictPort \
    </dev/null >"$LOG_DIR/frontend.log" 2>&1 &
  echo $! >"$FRONTEND_PID"
)

log "== 第 4 步：等待服务健康 =="
if ! wait_http "$BACKEND_URL/api/health" 30; then
  warn "后端未在 30s 内就绪，日志末尾："
  tail -n 20 "$LOG_DIR/backend.log" >&2 || true
  stop_pid_file "$FRONTEND_PID" "前端"; stop_pid_file "$BACKEND_PID" "后端"
  die "后端启动失败，详见 $LOG_DIR/backend.log"
fi
ok "后端健康检查通过：$BACKEND_URL/api/health"

if ! wait_http "$FRONTEND_URL/" 30; then
  warn "前端未在 30s 内就绪，日志末尾："
  tail -n 20 "$LOG_DIR/frontend.log" >&2 || true
  stop_pid_file "$FRONTEND_PID" "前端"; stop_pid_file "$BACKEND_PID" "后端"
  die "前端启动失败，详见 $LOG_DIR/frontend.log（端口被占用时请先 make down 或释放 ${FRONTEND_PORT}）"
fi
ok "前端已就绪：$FRONTEND_URL"

log "== 第 5 步：写入签发链路示例数据（待编制 → 已签发） =="
"$ROOT/backend/.venv/bin/python" scripts/run_report_flow.py \
  --base-url "$BACKEND_URL" --out "$FLOW_OUT" || {
    stop_pid_file "$FRONTEND_PID" "前端"; stop_pid_file "$BACKEND_PID" "后端"
    die "签发链路数据驱动失败，详见上方输出"
  }

log "== 第 6 步：可复现检查（报告结论 vs 接口返回，含前端代理） =="
if ! "$ROOT/backend/.venv/bin/python" scripts/verify_report.py \
    --backend "$BACKEND_URL" --frontend "$FRONTEND_URL"; then
  die "一致性检查未通过：报告结论与接口返回不一致（服务仍在运行，可用日志排查）"
fi

cat >&2 <<EOF

${C_GREEN}============================================================${C_RESET}
${C_GREEN}签发链路本地环境已就绪并通过检查${C_RESET}
  前端页面：  $FRONTEND_URL/report
  后端接口：  $BACKEND_URL/api/report
  健康检查：  $BACKEND_URL/api/health
  运行日志：  $LOG_DIR/{backend,frontend}.log
  签发记录：  $FLOW_OUT
  停止服务：  make down
  重复检查：  make check
${C_GREEN}============================================================${C_RESET}
EOF
