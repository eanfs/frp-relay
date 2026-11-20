#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/home/project/frps}"
CONTAINER="${CONTAINER:-1Panel-frps-Pjum}"
OLD_IMAGE="${OLD_IMAGE:-swr.cn-east-3.myhuaweicloud.com/intetech/frps:0.57.0}"
NEW_IMAGE="${NEW_IMAGE:-swr.cn-east-3.myhuaweicloud.com/intetech/frps:0.72.0}"
NEW_BIN="${NEW_BIN:-$APP_DIR/upgrade/frps-0.72.0}"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$APP_DIR/backup/$TS"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$NEW_BIN" ] || die "缺少新二进制: $NEW_BIN"
chmod +x "$NEW_BIN"
[ -f "$COMPOSE_FILE" ] || die "缺少 compose 文件: $COMPOSE_FILE"
[ -f "$APP_DIR/.env" ] || die "缺少 .env: $APP_DIR/.env"
docker image inspect "$OLD_IMAGE" >/dev/null 2>&1 || die "旧镜像不存在: $OLD_IMAGE"
command -v docker-compose >/dev/null 2>&1 || die "docker-compose 不存在"

log "备份到 $BK"
mkdir -p "$BK"
cp -a "$COMPOSE_FILE" "$APP_DIR/.env" "$APP_DIR/data.yml" "$APP_DIR/data/frps.toml" "$BK"/
docker inspect "$CONTAINER" > "$BK/container-inspect.json" 2>/dev/null || true

set -a
# shellcheck disable=SC1090
. "$APP_DIR/.env"
set +a
for type in tcp http https stcp; do
    curl -fsS -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:7500/api/proxy/$type" \
        > "$BK/proxy-$type.json" 2>/dev/null || true
done
curl -fsS -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:7500/api/serverinfo" \
    > "$BK/serverinfo.json" 2>/dev/null || true

log "构建新镜像 ${NEW_IMAGE}（基于本地旧镜像，离线）"
docker build -t "$NEW_IMAGE" "$APP_DIR/upgrade"
VERSION_OUT="$(docker run --rm --entrypoint /usr/bin/frps "$NEW_IMAGE" -v)"
[ "$VERSION_OUT" = "0.72.0" ] || die "新镜像版本异常: $VERSION_OUT"
log "新镜像版本校验通过: $VERSION_OUT"

log "切换 compose 镜像标签"
sed -i "s#${OLD_IMAGE}#${NEW_IMAGE}#g" "$COMPOSE_FILE"
grep -q "$NEW_IMAGE" "$COMPOSE_FILE" || die "compose 文件更新失败"

log "重建容器（会短暂中断所有代理）"
cd "$APP_DIR"
if ! docker-compose -f "$COMPOSE_FILE" up -d; then
    log "docker-compose up 失败，尝试 docker run 回退"
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" --network host --restart always \
        --label createdBy=Apps \
        -v "$APP_DIR/data/frps.toml:/etc/frp/frps.toml" \
        -v "$APP_DIR/data/ssl:/etc/frp/ssl" \
        "$NEW_IMAGE" >/dev/null
fi

log "等待 frps 就绪"
OK=0
for i in $(seq 1 30); do
    if curl -fsS -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:7500/api/serverinfo" \
        > /tmp/frps-serverinfo.json 2>/dev/null; then
        if grep -q '"version":"0.72.0"' /tmp/frps-serverinfo.json; then
            OK=1
            break
        fi
    fi
    sleep 1
done

if [ "$OK" -ne 1 ]; then
    log "frps 健康检查失败，自动回滚"
    "$APP_DIR/upgrade/rollback-frps.sh" "$BK" || true
    die "升级失败，已尝试回滚"
fi

log "frps 已升级到 0.72.0"
ss -lntp | grep -E ':(7000|7500|80|443)\b' || true
curl -sS -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:7500/api/serverinfo" | head -c 600
echo
log "完成。备份目录: $BK"
log "检查现有代理: curl -u ${USER_NAME}:<password> http://127.0.0.1:7500/api/proxy/tcp"
