#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/home/project/frps}"
CONTAINER="${CONTAINER:-1Panel-frps-Pjum}"
OLD_IMAGE="${OLD_IMAGE:-swr.cn-east-3.myhuaweicloud.com/intetech/frps:0.57.0}"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

BK="${1:-}"
if [ -z "$BK" ]; then
    BK="$(ls -1dt "$APP_DIR"/backup/* 2>/dev/null | head -1 || true)"
fi
[ -n "$BK" ] && [ -f "$BK/docker-compose.yml" ] || {
    echo "找不到备份目录或备份中的 docker-compose.yml"
    exit 1
}

echo "从 $BK 回滚"
cp -a "$BK/docker-compose.yml" "$COMPOSE_FILE"
grep -q "$OLD_IMAGE" "$COMPOSE_FILE" || {
    echo "备份中的镜像标签不是 $OLD_IMAGE"
    exit 1
}

cd "$APP_DIR"
if ! docker-compose -f "$COMPOSE_FILE" up -d; then
    echo "docker-compose up 失败，尝试 docker run 回退"
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" --network host --restart always \
        --label createdBy=Apps \
        -v "$APP_DIR/data/frps.toml:/etc/frp/frps.toml" \
        -v "$APP_DIR/data/ssl:/etc/frp/ssl" \
        "$OLD_IMAGE" >/dev/null
fi

set -a
# shellcheck disable=SC1090
. "$APP_DIR/.env"
set +a

for i in $(seq 1 30); do
    if curl -fsS -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:7500/api/serverinfo" 2>/dev/null \
        | grep -q '"version":"0.57.0"'; then
        echo "回滚成功：frps 0.57.0"
        exit 0
    fi
    sleep 1
done

echo "回滚后健康检查失败，请手动检查: docker logs $CONTAINER"
exit 1
