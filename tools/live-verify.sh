#!/usr/bin/env bash
# Verify the live frps with old and new clients on temporary remote ports.
# Requires FRP_TOKEN. Uses ports 60021 (frpc 0.57.0) and 60022 (frpc 0.72.0).
# Stop the production relay first if it is already using 60022.
set -euo pipefail

SERVER="${FRP_SERVER:-frps.example.com}"
SERVER_PORT="${FRP_SERVER_PORT:-7000}"
TOKEN="${FRP_TOKEN:-}"
WORK="${WORK:-/tmp/frp-relay-live}"
FRPC_072="$WORK/frp_0.72.0_darwin_amd64/frpc"
FRPC_057="$WORK/frp_0.57.0_darwin_amd64/frpc"

if [ -z "$TOKEN" ]; then
    echo "用法: FRP_TOKEN=<frps auth.token> $0"
    exit 1
fi

mkdir -p "$WORK"
PIDS=()
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { log "FAIL: $*"; exit 1; }
cleanup() {
    if [ "${#PIDS[@]}" -gt 0 ]; then
        for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
        wait 2>/dev/null || true
    fi
}
trap cleanup EXIT

sha256_check() {
    local file=$1 expected=$2 actual
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        actual=$(sha256sum "$file" | awk '{print $1}')
    fi
    [ "$actual" = "$expected" ] || fail "SHA256 mismatch: $file"
}

download_asset() {
    local version=$1 pattern=$2
    [ -f "$WORK/$pattern" ] && return 0
    log "下载 $pattern"
    if command -v gh >/dev/null 2>&1; then
        gh release download "v$version" --repo fatedier/frp --pattern "$pattern" --dir "$WORK" --clobber && return 0
    fi
    curl -fsSL --retry 8 --retry-delay 2 -o "$WORK/$pattern" \
        "https://github.com/fatedier/frp/releases/download/v${version}/${pattern}"
}

ensure_binaries() {
    download_asset 0.72.0 frp_0.72.0_darwin_amd64.tar.gz
    sha256_check "$WORK/frp_0.72.0_darwin_amd64.tar.gz" \
        60439dc6bf794c4182a1a4cac147d642f839d55201607208979eb23aecd09be9
    [ -d "$WORK/frp_0.72.0_darwin_amd64" ] || tar xzf "$WORK/frp_0.72.0_darwin_amd64.tar.gz" -C "$WORK"

    download_asset 0.57.0 frp_0.57.0_darwin_amd64.tar.gz
    sha256_check "$WORK/frp_0.57.0_darwin_amd64.tar.gz" \
        9a12912bfbf7dad0ebe5fb3b0229b318a8670d078137f2384f81c1aa87bc0fb0
    [ -d "$WORK/frp_0.57.0_darwin_amd64" ] || tar xzf "$WORK/frp_0.57.0_darwin_amd64.tar.gz" -C "$WORK"

    chmod +x "$FRPC_072" "$FRPC_057"
}

wait_port() {
    local host=$1 port=$2
    local i
    for i in $(seq 1 60); do
        if nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

tcp_echo() {
    local host=$1 port=$2
    python3 - "$host" "$port" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
sock = socket.create_connection((host, port), timeout=8)
try:
    sock.sendall(b"ping")
    sock.settimeout(8)
    sys.stdout.write(sock.recv(100).decode("utf-8", "replace"))
finally:
    sock.close()
PY
}

wait_port_closed() {
    local host=$1 port=$2
    local i
    for i in $(seq 1 40); do
        if ! nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

ensure_binaries

cat > "$WORK/echo_server.py" <<'PY'
import socket
import threading


def handle(conn):
    try:
        data = conn.recv(4096)
        conn.sendall(b"ECHO:" + data)
    finally:
        conn.close()


sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 2222))
sock.listen(50)
while True:
    conn, _ = sock.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

python3 "$WORK/echo_server.py" > "$WORK/echo.log" 2>&1 &
PIDS+=($!)
wait_port 127.0.0.1 2222 || fail "本机 echo 服务未启动"

test_live() {
    local binary=$1
    local tag=$2
    local remote_port=$3
    local user="live$tag"
    local cfg="$WORK/frpc-$tag.toml"

    cat > "$cfg" <<EOF
serverAddr = "$SERVER"
serverPort = $SERVER_PORT
user = "$user"
loginFailExit = true
log.to = "console"
log.level = "info"

auth.method = "token"
auth.token = "$TOKEN"
transport.tls.enable = true

[[proxies]]
name = "live-$tag"
type = "tcp"
localIP = "127.0.0.1"
localPort = 2222
remotePort = $remote_port
transport.useEncryption = true
EOF

    log "[$tag] 连接 ${SERVER}:${SERVER_PORT}，注册远程端口 ${remote_port}"
    "$binary" -c "$cfg" > "$WORK/frpc-$tag.log" 2>&1 &
    local pid=$!
    PIDS+=($pid)

    wait_port "$SERVER" "$remote_port" || fail "[$tag] 公网端口 $remote_port 未上线"
    sleep 1
    local out=""
    local i
    for i in 1 2 3 4 5 6; do
        out=$(tcp_echo "$SERVER" "$remote_port") || true
        [ "$out" = "ECHO:ping" ] && break
        sleep 1
    done
    [ "$out" = "ECHO:ping" ] || fail "[$tag] 隧道回显异常: $out"
    log "[$tag] PASS（${SERVER}:${remote_port}）"

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait_port_closed "$SERVER" "$remote_port" || log "[$tag] 警告：端口 $remote_port 未及时释放"
}

test_live "$FRPC_057" v57 60021
test_live "$FRPC_072" v72 60022

log "ALL PASS: live frps accepts frpc v0.57.0 (60021) and v0.72.0 (60022)"
