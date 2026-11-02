#!/bin/sh
# ============================================================
# 沙箱侧一键安装 / 恢复
#
#   bash sesame/install.sh            # 安装并启动
#   bash sesame/install.sh --once     # 只续期一次（冒烟测试）
#
# 做的事：
#   1. 生成反向隧道专用密钥（没有才生成）
#   2. 把中转机主机键钉进 known_hosts（支持传入已核实的指纹做校验）
#   3. 安装 keepalive.sh / tunnel.sh 到 /usr/local/bin
#   4. 用平台原生服务管理器注册为常驻服务（Sesame 无 systemd）
#   5. 打印还需要人工在中转机上做的那一步
# ============================================================
set -u

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo /nonexistent)
[ -f "$SELF_DIR/../.env" ] && . "$SELF_DIR/../.env"
[ -f "$SELF_DIR/.env" ] && . "$SELF_DIR/.env"

SPRITE_BIN=${SPRITE_BIN:-/.sprite/bin}
PATH="$SPRITE_BIN:$PATH"
export PATH

RELAY_HOST=${RELAY_HOST:?请先在 .env 里设置 RELAY_HOST}
TUNNEL_KEY=${TUNNEL_KEY:-$HOME/.ssh/tunnel}
KNOWN_HOSTS=${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
FINGERPRINT=${RELAY_HOST_FINGERPRINT:-}

say() { printf '  %s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# 服务以普通用户（uid≠0）运行，所以默认装到用户目录，全程不需要 root
BINDIR=${BINDIR:-$HOME/.local/bin}

# 必须跟 keepalive.sh / tunnel.sh 同目录（单拷 install.sh 跑不起来）
for f in keepalive.sh tunnel.sh; do
    [ -f "$SELF_DIR/$f" ] || die "缺少 $SELF_DIR/$f —— 请克隆整个仓库，而不是只拷 install.sh"
done

# ---------------------------------------------------------------- 1) 密钥
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ ! -f "$TUNNEL_KEY" ]; then
    ssh-keygen -t ed25519 -f "$TUNNEL_KEY" -N '' -C "tunnel@$(hostname 2>/dev/null || echo sandbox)" -q </dev/null
    say "已生成隧道密钥 $TUNNEL_KEY"
else
    say "复用已有隧道密钥 $TUNNEL_KEY"
fi
chmod 600 "$TUNNEL_KEY" 2>/dev/null
chmod 644 "$TUNNEL_KEY.pub" 2>/dev/null

# ---------------------------------------------------------------- 2) 主机键
if ssh-keygen -F "$RELAY_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    say "$RELAY_HOST 的主机键已在 known_hosts 中"
else
    say "正在获取 $RELAY_HOST 的主机键…"
    tmp=$(mktemp)
    ssh-keyscan -T 10 -t ed25519 "$RELAY_HOST" >"$tmp" 2>/dev/null || die "ssh-keyscan 失败"
    [ -s "$tmp" ] || die "未取到主机键"
    got=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}')
    if [ -n "$FINGERPRINT" ] && [ "$FINGERPRINT" != "$got" ]; then
        rm -f "$tmp"
        die "主机键指纹不匹配！期望 $FINGERPRINT，实际 $got —— 可能被中间人或 DNS 被劫持，已中止"
    fi
    [ -z "$FINGERPRINT" ] && say "⚠️  未提供期望指纹，已直接信任本次扫描结果（$got）"
    touch "$KNOWN_HOSTS" && chmod 600 "$KNOWN_HOSTS"
    cat "$tmp" >>"$KNOWN_HOSTS"
    rm -f "$tmp"
    say "已钉住主机键 $got"
fi

# ---------------------------------------------------------------- 3) 安装脚本
install -d -m 755 "$BINDIR"
install -m 755 "$SELF_DIR/keepalive.sh" "$BINDIR/sesame-keepalive.sh"
install -m 755 "$SELF_DIR/tunnel.sh" "$BINDIR/sesame-tunnel.sh"
say "已安装到 $BINDIR/sesame-{keepalive,tunnel}.sh"

sh -n "$BINDIR/sesame-keepalive.sh" || die "keepalive.sh 语法错误"
sh -n "$BINDIR/sesame-tunnel.sh" || die "tunnel.sh 语法错误"

# ---------------------------------------------------------------- 4) 服务
# 用平台原生服务管理器（无 systemd 时它就是唯一的自启/重启手段）
if ! command -v sprite-env >/dev/null 2>&1; then
    say "跳过快服务（非 Sesame 环境），可自行用 systemd/cron 托管上面两个脚本"
else
    for s in keepalive tunnel; do
        if sprite-env services list 2>/dev/null | grep -q "\"name\":\"$s\""; then
            sprite-env services restart "$s" >/dev/null 2>&1 && say "服务 $s 已重启" || say "服务 $s 重启失败"
        else
            sprite-env services create "$s" --cmd "$BINDIR/sesame-$s.sh" >/dev/null 2>&1 &&
                say "服务 $s 已创建" || say "服务 $s 创建失败"
        fi
    done
fi

# ---------------------------------------------------------------- 5) 收尾
echo
echo "=================================================================="
echo "还需在中转机上执行一次（把下面整行追加到 authorized_keys）："
echo
echo "command=\"/bin/false\",restrict,port-forwarding,permitlisten=\"${RELAY_LISTEN:-127.0.0.1:2222}\" $(cat "$TUNNEL_KEY.pub")"
echo
echo "然后在客户端：ssh -J ${RELAY_USER:-tunnel}@$RELAY_HOST -p 2222 <sandbox_user>@127.0.0.1"
echo "=================================================================="
