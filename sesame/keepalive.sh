#!/bin/sh
# ============================================================
# 沙箱活动租约续期（Sesame / Sprite 类平台）
#
# 背景：这类平台判定"活跃"的条件是「正在处理 HTTP 请求」或「detachable
#       session 有产出」。跑常驻进程、开着 SSH 都不算活跃，闲置到点就挂起。
#       通过本机 unix socket 提供的 PUT /v1/tasks/<name> 可以申请一段
#       "活动租约"，租约有效期内平台不会挂起；过期前续期即可长期在线。
#
# 用法：
#   keepalive.sh            # 常驻（给服务管理器用）
#   keepalive.sh --once     # 续一次就退出（用于冒烟测试 / cron）
#   keepalive.sh --status   # 打印当前租约
#
# 配置：同目录 .env，或环境变量（环境变量优先）
# ============================================================
set -u

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo /nonexistent)
[ -f "$SELF_DIR/.env" ] && . "$SELF_DIR/.env"
[ -f "$SELF_DIR/../.env" ] && . "$SELF_DIR/../.env"

SPRITE_BIN=${SPRITE_BIN:-/.sprite/bin}
# 非登录 shell 里 .sprite/bin 通常不在 PATH，必须显式补上
PATH="$SPRITE_BIN:$PATH"
export PATH

TASK_NAME=${TASK_NAME:-keepalive}
TASK_TTL=${TASK_TTL:-5m}
TASK_INTERVAL=${TASK_INTERVAL:-60}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}
LOG_KEEP=${LOG_KEEP:-3}
STATE_DIR=${STATE_DIR:-${HOME}/.local/state/sesame-keepalive}
LOG="$STATE_DIR/keepalive.log"
MAX_FAILS=${MAX_FAILS:-3}

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 日志
log() {
    line="$(date -u +%FT%TZ) $*"
    echo "$line"
    if [ -f "$LOG" ]; then
        size=$(wc -c <"$LOG" 2>/dev/null || echo 0)
    else
        size=0
    fi
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

# ---------------------------------------------------------------- 单实例
# flock 不一定有（BusyBox），退化用 mkdir 原子锁
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE_DIR/keepalive.lock" || return 1
        flock -n 9 || return 1
        return 0
    fi
    LOCKDIR="$STATE_DIR/keepalive.lock.d"
    if mkdir "$LOCKDIR" 2>/dev/null; then
        trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------- 续期
# PUT 是 upsert 语义：不存在则创建、已存在则续期。
# 注意：POST 只负责新建，重复 POST 会返回 409，不能用来续期。
renew() {
    resp=$(timeout 20 sprite-env curl -sS --connect-timeout 5 --max-time 15 \
        -X PUT "/v1/tasks/$TASK_NAME" \
        -d "{\"expire\":\"$TASK_TTL\"}" \
        -w '\n%{http_code}' 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERR  transport rc=$rc"
        return 1
    fi
    code=$(printf '%s' "$resp" | tail -n 1 | tr -d '\r')
    body=$(printf '%s' "$resp" | sed '$d')
    case "$code" in
        200 | 201 | 204)
            log "OK   http=$code $body"
            return 0
            ;;
        *)
            log "FAIL http=$code $body"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------- 入口
case "${1:---watch}" in
    --once)
        renew
        exit $?
        ;;
    --status)
        sprite-env curl -s /v1/tasks
        echo
        exit 0
        ;;
    --watch) ;;
    *)
        echo "用法: $0 [--watch|--once|--status]" >&2
        exit 2
        ;;
esac

command -v sprite-env >/dev/null 2>&1 || {
    log "FATAL sprite-env 不存在（不在 Sesame/Sprite 容器里？）"
    exit 1
}

acquire_lock || {
    log "已有实例在跑，退出"
    exit 0
}

trap 'exit 0' TERM INT

log "start task=$TASK_NAME ttl=$TASK_TTL interval=${TASK_INTERVAL}s pid=$$"

fails=0
while :; do
    if renew; then
        fails=0
    else
        fails=$((fails + 1))
        # 连续失败说明平台接口不可用：主动退出，交给服务管理器重启，
        # 避免脚本"卡在失败循环里却看起来还在运行"
        if [ "$fails" -ge "$MAX_FAILS" ]; then
            log "ALERT 连续 $fails 次失败，退出等待重启"
            exit 1
        fi
    fi
    sleep "$TASK_INTERVAL"
done
