#!/bin/sh
# ============================================================
# 一条命令做完运维自检（把 docs/04-runbook.md 的检查项合成一个脚本）
#
#   verify.sh            # 人类可读输出，退出码 0=健康 1=告警 2=异常
#   verify.sh --quiet    # 只输出有问题的行
#   verify.sh --json     # 机器可读
#
# 检查项
#   1. 服务状态（keepalive / tunnel 是否 running）
#   2. 活动租约是否在有效期内（剩余时间）
#   3. 心跳是否断档（> 1.5 倍间隔即告警）
#   4. 隧道是否出现过非预期重连
#   5. btime 是否与上次记录一致（变了 = 被暂停并恢复过）
#   6. sshd 是否只监听回环
# ============================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo /nonexistent)
for f in "$SELF_DIR/../.env" "$SELF_DIR/.env"; do
    [ -f "$f" ] && . "$f"
done

SPRITE_BIN=${SPRITE_BIN:-/.sprite/bin}
PATH="$SPRITE_BIN:$PATH"
export PATH

TASK_NAME=${TASK_NAME:-keepalive}
TASK_INTERVAL=${TASK_INTERVAL:-60}
STATE_DIR=${STATE_DIR:-$HOME/.local/state/sesame-keepalive}
KEEPALIVE_LOG="$STATE_DIR/keepalive.log"
TUNNEL_LOG="$STATE_DIR/tunnel.log"
BTIME_FILE="$STATE_DIR/last-btime"

QUIET=0
JSON=0
case "${1:-}" in
    --quiet) QUIET=1 ;;
    --json) JSON=1 ;;
    -h | --help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

RC=0
ok() {
    [ "$JSON" -eq 1 ] && return
    [ "$QUIET" -eq 0 ] && printf '  \033[32mOK\033[0m   %s\n' "$*"
}
warn() {
    RC=$((RC < 1 ? 1 : RC))
    [ "$JSON" -eq 1 ] && return
    printf '  \033[33mWARN\033[0m %s\n' "$*"
}
bad() {
    RC=2
    [ "$JSON" -eq 1 ] && return
    printf '  \033[31mFAIL\033[0m %s\n' "$*"
}
title() { [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ] && printf '\n%s\n' "$*"; }

JH=''
jadd() { JH="$JH${JH:+,}\"$1\":\"$2\""; }

# ---------------------------------------------------------------- 1) 服务
title "1) 平台服务"
SVC_LIST=$(sprite-env services list 2>/dev/null || echo '')
if [ -z "$SVC_LIST" ]; then
    warn "读不到服务列表（不是 Sesame 环境，或 sprite-env 不可用）"
else
    for s in keepalive tunnel; do
        if printf '%s' "$SVC_LIST" | grep -q "\"name\":\"$s\"" &&
            printf '%s' "$SVC_LIST" | grep -q "\"status\":\"running\""; then
            ok "$s 运行中"
        else
            bad "$s 未运行（sprite-env services list 查看）"
        fi
    done
fi

# ---------------------------------------------------------------- 2) 租约
title "2) 活动租约"
TASKS=$(sprite-env curl -s /v1/tasks 2>/dev/null || echo '')
EXPIRES=$(printf '%s' "$TASKS" | sed -n 's/.*"expires_at":"\([^"]*\)".*/\1/p' | head -n 1)
if [ -z "$EXPIRES" ]; then
    bad "没有活动租约（机器随时可能被挂起）"
else
    exp_s=$(date -u -d "$EXPIRES" +%s 2>/dev/null || echo 0)
    now_s=$(date -u +%s)
    left=$((exp_s - now_s))
    if [ "$left" -gt 0 ]; then
        ok "租约剩余 ${left}s（到期 $EXPIRES）"
        jadd lease_left "$left"
    else
        bad "租约已过期 ${left#-}s"
    fi
fi

# ---------------------------------------------------------------- 3) 心跳
title "3) 心跳连续性"
if [ -f "$KEEPALIVE_LOG" ]; then
    limit=$((TASK_INTERVAL * 3 / 2))
    gaps=$(grep '^20' "$KEEPALIVE_LOG" 2>/dev/null |
        awk '{print $1}' |
        while read -r t; do date -u -d "$t" +%s 2>/dev/null; done |
        awk -v lim="$limit" 'NR>1{d=$1-p; if(d>lim) print d} {p=$1}')
    if [ -n "$gaps" ]; then
        warn "存在心跳断档（秒）：$(printf '%s' "$gaps" | tr '\n' ' ')"
    else
        ok "无断档（阈值 ${limit}s）"
    fi
    ok_last=$(grep -c 'lease renewed\|OK ' "$KEEPALIVE_LOG" 2>/dev/null || echo 0)
    ok "历史成功续期 ${ok_last} 次"
    jadd renew_ok "$ok_last"
else
    warn "找不到 $KEEPALIVE_LOG"
fi

# ---------------------------------------------------------------- 4) 隧道
title "4) 隧道稳定性"
if [ -f "$TUNNEL_LOG" ]; then
    restarts=$(grep -c 'ssh 退出\|ssh exited' "$TUNNEL_LOG" 2>/dev/null || echo 0)
    starts=$(grep -c 'start ' "$TUNNEL_LOG" 2>/dev/null || echo 0)
    jadd tunnel_restarts "$restarts"
    if [ "$restarts" -eq 0 ]; then
        ok "无重连记录（启动 ${starts} 次）"
    else
        warn "重连 ${restarts} 次（若含手动重启属正常）"
    fi
    last=$(tail -n 1 "$TUNNEL_LOG" 2>/dev/null)
    [ "$QUIET" -eq 0 ] && [ "$JSON" -eq 0 ] && printf '        最后一行: %s\n' "$last"
else
    warn "找不到 $TUNNEL_LOG"
fi

# ---------------------------------------------------------------- 5) btime
title "5) 是否被暂停并恢复过"
BT=$(awk '/btime/{print $2}' /proc/stat 2>/dev/null)
if [ -n "$BT" ]; then
    if [ -f "$BTIME_FILE" ]; then
        prev=$(cat "$BTIME_FILE" 2>/dev/null)
        # btime 是 wall-uptic 相减取整，会 ±1 抖动；差 2 以内视为未变
        diff=$((BT - prev))
        [ "$diff" -lt 0 ] && diff=$((-diff))
        if [ "$diff" -le 2 ]; then
            ok "btime 未变（$BT）"
        else
            warn "btime 变化 $prev → $BT（期间被暂停并恢复过，属预期行为）"
        fi
    else
        ok "记录基线 btime=$BT"
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$BT" >"$BTIME_FILE" 2>/dev/null
    jadd btime "$BT"
else
    warn "读不到 btime"
fi

# ---------------------------------------------------------------- 6) sshd
title "6) sshd 监听"
if command -v ss >/dev/null 2>&1; then
    listens=$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}')
    if printf '%s\n' "$listens" | grep -qE '^(0\.0\.0\.0|\*|\[::\]):22$'; then
        warn "sshd 监听在通配地址（建议只绑 127.0.0.1，用隧道进来）"
    elif printf '%s\n' "$listens" | grep -qE '^127\.0\.0\.1:22$'; then
        ok "sshd 只监听 127.0.0.1:22"
    else
        warn "没看到 22 端口在监听"
    fi
else
    warn "没有 ss 命令，跳过"
fi

# ---------------------------------------------------------------- 输出
if [ "$JSON" -eq 1 ]; then
    printf '{"rc":%d,%s}\n' "$RC" "$JH"
else
    case "$RC" in
        0) [ "$QUIET" -eq 0 ] && printf '\n结论: 健康\n' ;;
        1) printf '\n结论: 有告警，见上方 WARN\n' ;;
        *) printf '\n结论: 异常，需处理\n' ;;
    esac
fi

exit "$RC"
