#!/usr/bin/env bash
# Verify that frpc v0.57.0 and v0.72.0 can talk to frps v0.72.0.
# Runs entirely on this machine; no changes to the live frps.
set -euo pipefail

WORK="${WORK:-/tmp/frp-relay-compat}"
FRPS_072="$WORK/frp_0.72.0_darwin_amd64/frps"
FRPC_072="$WORK/frp_0.72.0_darwin_amd64/frpc"
FRPC_057="$WORK/frp_0.57.0_darwin_amd64/frpc"

mkdir -p "$WORK"
PIDS=()

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { log "FAIL: $*"; exit 1; }

cleanup() {
    if [ "${#PIDS[@]}" -gt 0 ]; then
        for p in "${PIDS[@]}"; do
            kill "$p" 2>/dev/null || true
        done
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

    chmod +x "$FRPS_072" "$FRPC_072" "$FRPC_057"
}

wait_port() {
    local host=$1 port=$2
    local i
    for i in $(seq 1 50); do
        if nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

tcp_echo() {
    local host=$1 port=$2
    python3 - "$host" "$port" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
sock = socket.create_connection((host, port), timeout=5)
try:
    sock.sendall(b"ping")
    sock.settimeout(5)
    sys.stdout.write(sock.recv(100).decode("utf-8", "replace"))
finally:
    sock.close()
PY
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

mkdir -p "$WORK/www"
echo "compat-ok" > "$WORK/www/index.html"

python3 "$WORK/echo_server.py" > "$WORK/echo.log" 2>&1 &
PIDS+=($!)
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$WORK/www" > "$WORK/http.log" 2>&1 &
PIDS+=($!)

wait_port 127.0.0.1 2222 || fail "本机 echo 服务未启动"
wait_port 127.0.0.1 8080 || fail "本机 HTTP 服务未启动"

cat > "$WORK/frps.toml" <<'EOF'
bindAddr = "127.0.0.1"
bindPort = 17000
vhostHTTPPort = 18080

auth.method = "token"
auth.token = "compat-token"

webServer.addr = "127.0.0.1"
webServer.port = 17500
webServer.user = "admin"
webServer.password = "compat-pass"

log.to = "console"
log.level = "info"
EOF

"$FRPS_072" -c "$WORK/frps.toml" > "$WORK/frps.log" 2>&1 &
PIDS+=($!)

wait_port 127.0.0.1 17000 || fail "frps 未监听 17000"
wait_port 127.0.0.1 17500 || fail "frps 面板未监听 17500"
log "frps v0.72.0 已启动"

test_client() {
    local binary=$1
    local tag=$2
    local tcp_port=$3
    local stcp_port=$4
    local user="compat$tag"
    local frpc_cfg="$WORK/frpc-$tag.toml"
    local visitor_cfg="$WORK/visitor-$tag.toml"

    cat > "$frpc_cfg" <<EOF
serverAddr = "127.0.0.1"
serverPort = 17000
user = "$user"
loginFailExit = true
log.to = "console"
log.level = "info"

auth.method = "token"
auth.token = "compat-token"
transport.tls.enable = true

[[proxies]]
name = "tcp-$tag"
type = "tcp"
localIP = "127.0.0.1"
localPort = 2222
remotePort = $tcp_port

[[proxies]]
name = "http-$tag"
type = "http"
localIP = "127.0.0.1"
localPort = 8080
customDomains = ["compat.local"]

[[proxies]]
name = "stcp-$tag"
type = "stcp"
secretKey = "compat-secret"
localIP = "127.0.0.1"
localPort = 2222
allowUsers = ["$user"]
EOF

    cat > "$visitor_cfg" <<EOF
serverAddr = "127.0.0.1"
serverPort = 17000
user = "$user"
loginFailExit = true
log.to = "console"
log.level = "info"

auth.method = "token"
auth.token = "compat-token"
transport.tls.enable = true

[[visitors]]
name = "stcp-$tag-visitor"
type = "stcp"
serverUser = "$user"
serverName = "stcp-$tag"
secretKey = "compat-secret"
bindAddr = "127.0.0.1"
bindPort = $stcp_port
EOF

    log "[$tag] 启动 frpc"
    "$binary" -c "$frpc_cfg" > "$WORK/frpc-$tag.log" 2>&1 &
    local frpc_pid=$!
    PIDS+=($frpc_pid)

    wait_port 127.0.0.1 "$tcp_port" || fail "[$tag] TCP 代理未上线"
    sleep 0.5
    local out=""
    local i
    for i in 1 2 3 4 5; do
        out=$(tcp_echo 127.0.0.1 "$tcp_port") || true
        [ "$out" = "ECHO:ping" ] && break
        sleep 0.5
    done
    [ "$out" = "ECHO:ping" ] || fail "[$tag] TCP 隧道回显异常: $out"
    log "[$tag] TCP OK"

    for i in 1 2 3 4 5; do
        out=$(curl -fsS -H "Host: compat.local" http://127.0.0.1:18080/ 2>/dev/null) || true
        [ "$out" = "compat-ok" ] && break
        sleep 0.5
    done
    [ "$out" = "compat-ok" ] || fail "[$tag] HTTP 返回异常: $out"
    log "[$tag] HTTP OK"

    "$binary" -c "$visitor_cfg" > "$WORK/visitor-$tag.log" 2>&1 &
    local visitor_pid=$!
    PIDS+=($visitor_pid)

    wait_port 127.0.0.1 "$stcp_port" || fail "[$tag] STCP visitor 未监听"
    sleep 0.5
    for i in 1 2 3 4 5; do
        out=$(tcp_echo 127.0.0.1 "$stcp_port") || true
        [ "$out" = "ECHO:ping" ] && break
        sleep 0.5
    done
    [ "$out" = "ECHO:ping" ] || fail "[$tag] STCP 隧道回显异常: $out"
    log "[$tag] STCP OK"

    kill "$frpc_pid" "$visitor_pid" 2>/dev/null || true
    wait "$frpc_pid" "$visitor_pid" 2>/dev/null || true
    log "[$tag] PASS"
}

test_client "$FRPC_057" v57 16021 16023
test_client "$FRPC_072" v72 16022 16024

curl -fsS -u admin:compat-pass http://127.0.0.1:17500/api/serverinfo | grep -q '"version":"0.72.0"' \
    || fail "frps 面板版本不是 0.72.0"

log "ALL PASS: frpc v0.57.0 and v0.72.0 are compatible with frps v0.72.0"
log "日志目录: $WORK"
