#!/usr/bin/env bash
# 本地联调脚本共用的工具函数：日志、端口探测、HTTP 等待、进程清理。
# 只依赖 bash 3+ 与 python3（HTTP/端口探测统一走 python 标准库，不要求 curl/lsof）。

# 颜色在非 TTY 环境自动降级，避免日志里出现一堆转义码。
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

log()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# 判断 127.0.0.1:PORT 是否空闲：空闲返回 0，被占用返回 1。
port_is_free() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(0.5)
result = sock.connect_ex(("127.0.0.1", int(sys.argv[1])))
sock.close()
sys.exit(0 if result != 0 else 1)
PY
}

# 尽量找到占用端口的进程 pid 列表，找不到就返回空串。
# 优先 lsof/fuser；都没有时在 Linux 上解析 /proc/net/tcp + /proc/*/fd，
# 保证精简容器里也能给出占用进程。
port_owner() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2}' | sort -u
    return
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "$port"/tcp 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
    return
  fi
  python3 - "$port" <<'PY' 2>/dev/null || true
import os, sys
port_hex = f"{int(sys.argv[1]):04X}"
inodes = set()
for table in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        with open(table) as fh:
            for line in fh.readlines()[1:]:
                parts = line.split()
                local, state = parts[1], parts[3]
                # 0A = LISTEN
                if local.rsplit(":", 1)[1] == port_hex and state == "0A":
                    inodes.add(parts[9])
    except (OSError, IndexError):
        pass
pids = set()
if inodes:
    for pid in filter(str.isdigit, os.listdir("/proc")):
        fddir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fddir):
                try:
                    target = os.readlink(f"{fddir}/{fd}")
                except OSError:
                    continue
                if target.startswith("socket:[") and target[8:-1] in inodes:
                    pids.add(pid)
        except OSError:
            continue
print(" ".join(sorted(pids, key=int)))
PY
}

# 轮询等待一个 HTTP 接口返回 2xx：参数 URL 超时秒数。
wait_http() {
  local url="$1" timeout="${2:-60}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if python3 - "$url" <<'PY'
import json, sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=2) as resp:
        if 200 <= resp.status < 300:
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
    then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# 按 pid 文件停进程；文件缺失或进程已退出都不算错。
stop_pid_file() {
  local pid_file="$1" name="$2"
  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
      sleep 0.3; i=$((i + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
    log "已停止${name}（pid $pid）"
  fi
  rm -f "$pid_file"
}
