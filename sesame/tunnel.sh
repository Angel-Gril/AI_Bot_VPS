#!/bin/sh
# ============================================================
# 反向 SSH 隧道守护：沙箱(127.0.0.1:22) ←→ 中转机(127.0.0.1:2222)
#
# 设计要点
#   1. 由沙箱主动拨出，所以沙箱有没有公网 IP 都无所谓；
#   2. 中转侧监听地址写死 127.0.0.1，不经过 GatewayPorts，公网扫不到；
#   3. 主机键 pinning：StrictHostKeyChecking=yes + 固定 known_hosts，
#      DNS 投毒 / 中间人都过不去；
#   4. 断线指数退避（5s → 60s），恢复后自动回到 5s。
#
# 配置：同目录 .env 或环境变量
# ============================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo /nonexistent)
[ -f "$SELF_DIR/.env" ] && . "$SELF_DIR/.env"
[ -f "$SELF_DIR/../.env" ] && . "$SELF_DIR/../.env"

RELAY_HOST=${RELAY_HOST:?未设置 RELAY_HOST（见 .env.example）}
RELAY_PORT=${RELAY_PORT:-22}
RELAY_USER=${RELAY_USER:-tunnel}
RELAY_LISTEN=${RELAY_LISTEN:-127.0.0.1:2222}
SANDBOX_TARGET=${SANDBOX_TARGET:-127.0.0.1:22}
TUNNEL_KEY=${TUNNEL_KEY:-$HOME/.ssh/tunnel}
KNOWN_HOSTS=${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}
LOG_KEEP=${LOG_KEEP:-3}
STATE_DIR=${STATE_DIR:-$HOME/.local/state/sesame-keepalive}
LOG="$STATE_DIR/tunnel.log"

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
    line="$(date -u +%FT%TZ) $*"
    echo "$line"
    if [ -f "$LOG" ]; then size=$(wc -c <"$LOG" 2>/dev/null || echo 0); else size=0; fi
    if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
        i=$((LOG_KEEP - 1))
        while [ "$i" -ge 1 ]; do
            [ -f "$LOG.$i" ] && mv -f "$LOG.$i" "$LOG.$((i + 1))"
            i=$((i - 1))
        done
        mv -f "$LOG" "$LOG.1"
    fi
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------- 前置检查
[ -r "$TUNNEL_KEY" ] || {
    log "FATAL 缺少隧道私钥 $TUNNEL_KEY（先跑 install.sh 生成）"
    exit 1
}
[ -r "$KNOWN_HOSTS" ] || {
    log "FATAL 缺少 $KNOWN_HOSTS（先跑 install.sh 钉住中转机主机键）"
    exit 1
}
# 主机键必须已 pin，否则拒绝启动——宁可连不上，也不要盲信
ssh-keygen -F "$RELAY_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || {
    log "FATAL $RELAY_HOST 的主机键未钉住，拒绝启动（防止中间人）"
    exit 1
}

# ---------------------------------------------------------------- 单实例
if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE_DIR/tunnel.lock" || exit 1
    flock -n 9 || {
        log "已有实例在跑，退出"
        exit 0
    }
fi

child=
cleanup() {
    trap - EXIT TERM INT
    [ -n "$child" ] && kill "$child" 2>/dev/null && wait "$child" 2>/dev/null
    exit 0
}
trap cleanup EXIT TERM INT

log "start $RELAY_LISTEN → $SANDBOX_TARGET via $RELAY_USER@$RELAY_HOST:$RELAY_PORT"

delay=5
while :; do
    started=$SECONDS
    # -F /dev/null：忽略本机 ssh config，避免被无关配置干扰
    ssh -F /dev/null -N -T \
        -p "$RELAY_PORT" \
        -o ExitOnForwardFailure=yes \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o ConnectTimeout=15 \
        -o ConnectionAttempts=1 \
        -o LogLevel=ERROR \
        -i "$TUNNEL_KEY" \
        -R "$RELAY_LISTEN:$SANDBOX_TARGET" \
        "$RELAY_USER@$RELAY_HOST" >>"$LOG" 2>&1 &
    child=$!
    if wait "$child"; then rc=0; else rc=$?; fi
    child=

    # 撑过 60s 视为"真的连通过"，重置退避；否则快速失败时逐步拉长间隔
    if [ $((SECONDS - started)) -ge 60 ]; then delay=5; fi
    log "ssh 退出 rc=$rc，${delay}s 后重连"
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 60 ] && delay=60
done
