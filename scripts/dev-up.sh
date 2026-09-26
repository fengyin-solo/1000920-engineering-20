#!/usr/bin/env bash
# 检测报告签发链路 · 本地一键联调启动脚本
#
# 做的事情：
#   1. 预检 python3 / node / npm 是否安装，缺一个都给出明确安装提示；
#   2. 预检后端 8000、前端 5173 端口是否被占用，被占用直接报错并给出排查命令；
#   3. 按需准备后端 .venv 依赖与前端 node_modules；
#   4. 构建前端（vue-tsc 类型检查 + vite build）；
#   5. 后台拉起后端（uvicorn）与前端（vite preview 跑构建产物），等待健康检查通过；
#   6. 打印从「待编制」到「已签发」的示例数据清单与后续命令。
#
# 后端是内存仓库，启动即写入示例数据（见 backend/app/seed.py），
# 报告模块固定包含 待编制/待审核/待签发/已签发 各一条，含报告编号、编制人、签发人。
#
# 可用环境变量覆盖默认值：
#   BACKEND_PORT=8000  FRONTEND_PORT=5173
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
FRONTEND_URL="http://127.0.0.1:${FRONTEND_PORT}"
RUN_DIR="$ROOT_DIR/.run"
LOG_DIR="$RUN_DIR/logs"
BACKEND_PID="$RUN_DIR/backend.pid"
FRONTEND_PID="$RUN_DIR/frontend.pid"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info()  { printf '%s\n' "${BOLD}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()    { printf '%s\n' "${GREEN}[OK]${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}[WARN]${RESET} $*"; }
die()   { printf '%s\n' "${RED}[ERROR]${RESET} $*" >&2; exit "${2:-1}"; }

pid_alive() { kill -0 "$1" 2>/dev/null; }

# ---------- 预检：基础命令 ----------
missing=()
for cmd in python3 node npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  printf '%s\n' "${RED}[ERROR] 缺少必需依赖：${missing[*]}${RESET}" >&2
  cat >&2 <<'HINT'
        安装方式（Debian/Ubuntu）：
          apt-get update && apt-get install -y python3 python3-venv nodejs npm
        macOS：
          brew install python node
        或参考 README.md「签发链路一键联调」一节。
HINT
  exit 2
fi
ok "基础依赖齐全：$(python3 --version 2>&1)、$(node --version)、npm $(npm --version)"

# ---------- 预检：是否已有本脚本拉起的服务 ----------
stale_pids=()
for pf in "$BACKEND_PID" "$FRONTEND_PID"; do
  if [ -f "$pf" ]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && pid_alive "$pid"; then
      stale_pids+=("$pid")
    else
      rm -f "$pf"
    fi
  fi
done
if [ "${#stale_pids[@]}" -gt 0 ]; then
  die "检测到本地联调服务仍在运行（PID: ${stale_pids[*]}）。
        先执行 scripts/dev-down.sh（或 make dev-down）停止后再启动。" 2
fi

# ---------- 预检：端口占用 ----------
check_port() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}
for spec in "${BACKEND_PORT}:后端" "${FRONTEND_PORT}:前端"; do
  port="${spec%%:*}"; label="${spec##*:}"
  if ! check_port "$port"; then
    die "端口 ${port}（${label}）已被占用，本脚本不会抢占。
        排查占用进程：ss -ltnp | grep ':${port}'    （或 lsof -i :${port}）
        如确认无用可结束该进程，或用 BACKEND_PORT/FRONTEND_PORT 换端口启动。" 2
  fi
done
ok "端口检查通过：后端 ${BACKEND_PORT}、前端 ${FRONTEND_PORT} 均空闲"

# ---------- 准备后端依赖 ----------
info "准备后端 Python 虚拟环境与依赖..."
if [ ! -x "$BACKEND_DIR/.venv/bin/python" ]; then
  venv_err="$(mktemp)"
  if ! python3 -m venv "$BACKEND_DIR/.venv" 2> "$venv_err"; then
    cat "$venv_err" >&2 || true
    rm -f "$venv_err"
    die "创建 Python 虚拟环境失败。Debian/Ubuntu 需先安装 python3-venv：
          apt-get install -y python3-venv" 3
  fi
  rm -f "$venv_err"
fi
if ! "$BACKEND_DIR/.venv/bin/pip" install -q -r "$BACKEND_DIR/requirements.txt"; then
  die "后端依赖安装失败，请检查网络或 requirements.txt。" 3
fi
ok "后端依赖就绪"

# ---------- 准备前端依赖 ----------
if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
  info "安装前端依赖（首次较慢）..."
  if ! (cd "$FRONTEND_DIR" && npm install); then
    die "前端依赖安装失败，请查看上方 npm 输出。" 3
  fi
fi
ok "前端依赖就绪"

# ---------- 构建前端 ----------
info "构建前端（npm run build：vue-tsc 类型检查 + vite build）..."
if ! (cd "$FRONTEND_DIR" && npm run build); then
  die "前端构建失败，请先修复上方类型或构建错误。" 3
fi
ok "前端构建完成，产物在 frontend/dist"

mkdir -p "$LOG_DIR"

# 启动后若任一步失败（如前端健康检查超时），自动回收已拉起的服务，避免残留占端口。
STARTED_PIDS=()
cleanup_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
    printf '\n%s 启动失败，正在回收已拉起的服务...\n' "${RED}[ERROR]${RESET}" >&2
    for pid in "${STARTED_PIDS[@]}"; do
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${STARTED_PIDS[@]}"; do
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    done
    rm -f "$BACKEND_PID" "$FRONTEND_PID"
  fi
  exit "$rc"
}
trap cleanup_on_failure EXIT

# 以新会话/进程组方式启动，pidfile 记录会话首领 PID（exec 后即服务自身 PID），
# dev-down 用负 PID 整组回收（含 npm 派生的 vite 子进程）。
start_service() {
  local name="$1" workdir="$2" logfile="$3" pidfile="$4"; shift 4
  info "启动${name}，日志：${logfile#$ROOT_DIR/}"
  if command -v setsid >/dev/null 2>&1; then
    # --fork 让 setsid 先 fork 再进新会话，首领进程 exec 成目标服务。
    (cd "$workdir" && setsid --fork bash -c 'echo "$$" > "$1"; shift; exec "$@"' _ \
      "$pidfile" "$@" >"$logfile" 2>&1 </dev/null &)
  else
    warn "未找到 setsid，${name}将以普通后台进程启动，停止时可能残留子进程"
    (cd "$workdir" && bash -c 'echo "$$" > "$1"; shift; exec "$@"' _ \
      "$pidfile" "$@" >"$logfile" 2>&1 </dev/null &)
  fi
}

# ---------- 健康检查轮询（纯标准库，不依赖 curl） ----------
wait_http() {
  local url="$1" timeout_sec="$2" logfile="$3" label="$4"
  python3 - "$url" "$timeout_sec" <<'PY'
import sys, time, urllib.request
url, deadline = sys.argv[1], time.time() + int(sys.argv[2])
last_err = ""
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            if 200 <= resp.status < 500:
                sys.exit(0)
    except Exception as exc:  # noqa: BLE001 - 启动期任何异常都继续轮询
        last_err = str(exc)
    time.sleep(0.5)
print(last_err, file=sys.stderr)
sys.exit(1)
PY
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "---- ${label} 日志末尾 ----" >&2
    tail -n 30 "$logfile" >&2 || true
    die "${label}在 ${timeout_sec}s 内未就绪（${url}），日志见 ${logfile#$ROOT_DIR/}" 4
  fi
}

# ---------- 启动后端 ----------
start_service "后端 uvicorn" "$BACKEND_DIR" "$LOG_DIR/backend.log" "$BACKEND_PID" \
  "$BACKEND_DIR/.venv/bin/uvicorn" app.main:app --host 127.0.0.1 --port "$BACKEND_PORT"
wait_http "$BACKEND_URL/api/health" 30 "$LOG_DIR/backend.log" "后端"
STARTED_PIDS+=("$(cat "$BACKEND_PID")")
ok "后端已就绪：${BACKEND_URL}（PID $(cat "$BACKEND_PID")）"

# ---------- 启动前端（构建产物 + /api 代理到后端） ----------
start_service "前端 vite preview" "$FRONTEND_DIR" "$LOG_DIR/frontend.log" "$FRONTEND_PID" \
  env VITE_PORT="$FRONTEND_PORT" VITE_PROXY_TARGET="$BACKEND_URL" npm run preview
wait_http "$FRONTEND_URL/" 30 "$LOG_DIR/frontend.log" "前端"
STARTED_PIDS+=("$(cat "$FRONTEND_PID")")
ok "前端已就绪：${FRONTEND_URL}（PID $(cat "$FRONTEND_PID")）"

# ---------- 验证前后端联通（经前端代理打后端健康检查） ----------
if ! python3 - "$FRONTEND_URL/api/health" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
then
  die "前端已起，但经前端访问后端 ${FRONTEND_URL}/api/health 失败，代理未打通。" 4
fi
ok "前后端联通正常：${FRONTEND_URL}/api -> ${BACKEND_URL}"

# ---------- 打印示例数据里的报告签发链路 ----------
info "报告模块示例数据（后端启动时写入内存仓库）："
python3 - "$BACKEND_URL" <<'PY'
import json, sys, urllib.parse, urllib.request
base = sys.argv[1].rstrip("/")
statuses = ["待编制", "待审核", "待签发", "已签发"]
for status in statuses:
    url = f"{base}/api/report?status={urllib.parse.quote(status)}&size=200"
    with urllib.request.urlopen(url, timeout=5) as resp:
        items = json.loads(resp.read())["items"]
    for row in items:
        print(
            f"  {status:<4} 编号={row.get('报告编号', ''):<16} "
            f"编制人={row.get('编制人', '') or '—':<6} "
            f"审核人={row.get('审核人', '') or '—':<6} "
            f"签发人={row.get('签发人', '') or '—':<6}"
        )
PY

cat <<EOF

${GREEN}${BOLD}本地联调环境已拉起：${RESET}
  前端页面：  ${FRONTEND_URL}/   （报告页：${FRONTEND_URL}/report）
  后端接口：  ${BACKEND_URL}/api/health  （接口文档：${BACKEND_URL}/docs）
  运行日志：  .run/logs/backend.log、.run/logs/frontend.log

下一步：
  1) 浏览器打开 ${FRONTEND_URL}/report，可看到 待编制→待审核→待签发→已签发 示例数据；
  2) 跑可复现的签发链路检查脚本（会新建一份报告，逐段推进到已签发，
     并比对明细/列表/导出三个接口返回的报告结论）：
       scripts/check_report_chain.py
  3) 停止服务：scripts/dev-down.sh（或 make dev-down）
EOF
