#!/usr/bin/env bash
# ============================================================
# 敏感信息自查（本地与 CI 共用）
#
#   bash scripts/secret-scan.sh
#
# 三道检查：
#   A. 密钥 / 令牌形态
#   B. 真实 IP（只允许回环 + RFC 5737 文档段）
#   C. 不该进版本库的文件是否被跟踪（.env、日志、known_hosts、私钥）
#
# 退出码：0 = 干净，1 = 发现问题
# ============================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

fail=0
report() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# 取要检查的文件：git 仓库内只查被跟踪文件，否则查全量
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t FILES < <(git ls-files)
    SCOPE="git 跟踪的 $((${#FILES[@]})) 个文件"
else
    mapfile -t FILES < <(find . -type f \
        -not -path './.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*')
    SCOPE="目录下 $((${#FILES[@]})) 个文件"
fi
printf '\n== 扫描范围：%s ==\n' "$SCOPE"

# ---------------------------------------------------------------- A) 密钥形态
printf '\nA) 密钥 / 令牌形态\n'
# 说明：占位符形如 <PUBKEY>、sk-xxx、ibk_xxx 不计入（阈值取长度）
PATTERN='BEGIN [A-Z ]*PRIVATE KEY'
PATTERN+='|gh[pousr]_[A-Za-z0-9]{30,}'
PATTERN+='|github_pat_[A-Za-z0-9_]{30,}'
PATTERN+='|\bsk-[A-Za-z0-9_-]{32,}'
PATTERN+='|\bibk_[A-Za-z0-9]{16,}'
PATTERN+='|\bAKIA[0-9A-Z]{16}\b'
PATTERN+='|ssh-(rsa|ed25519) AAAA[A-Za-z0-9+/]{60,}'

# bash 手册页样例里的假 key 与 fixtures 里的示例公钥允许
ALLOWLIST_FILE=".secretscan-allow"
hits=""
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    case "$f" in *.png | *.jpg | *.webp | *.gif | *.ico) continue ;; esac
    out=$(grep -nEI "$PATTERN" "$f" 2>/dev/null || true)
    [ -z "$out" ] && continue
    if [ -f "$ALLOWLIST_FILE" ] && grep -qxF "$f" "$ALLOWLIST_FILE"; then
        printf '  \033[33m·\033[0m %s（在 allowlist 中）\n' "$f"
        continue
    fi
    hits+="$f: $out"$'\n'
done
if [ -n "$hits" ]; then
    printf '%s' "$hits" | sed 's/^/     /'
    report "发现疑似密钥/令牌"
else
    pass "无私钥、无令牌"
fi

# ---------------------------------------------------------------- B) 真实 IP
printf '\nB) 真实 IP（只允许回环与 RFC 5737 文档段）\n'
IPS=$(grep -hoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "${FILES[@]}" 2>/dev/null | sort -u)
bad_ips=""
while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    case "$ip" in
        127.0.0.1 | 0.0.0.0) ;;
        203.0.113.* | 198.51.100.* | 192.0.2.*) ;;   # RFC 5737 文档专用
        *) bad_ips+="$ip " ;;
    esac
done <<<"$IPS"
if [ -n "$bad_ips" ]; then
    report "出现非文档地址：$bad_ips"
else
    pass "IP 全部为回环/文档段（$(printf '%s' "$IPS" | tr '\n' ' ' | sed 's/ $//')）"
fi

# ---------------------------------------------------------------- C) 不该跟踪的文件
printf '\nC) 不该进版本库的文件\n'
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked=$(git ls-files | grep -E '(^|/)(\.env$|\.env\.[a-z]+$)|(\.log|\.log\.[0-9]+)$|(^|/)known_hosts|\.pem$|\.key$|id_(rsa|ed25519)' || true)
    # 允许 .env.example
    tracked=$(printf '%s\n' "$tracked" | grep -v '^\.env\.example$' | grep -v '^$' || true)
    if [ -n "$tracked" ]; then
        printf '%s\n' "$tracked" | sed 's/^/     /'
        report "上述文件被跟踪了（应加入 .gitignore）"
    else
        pass ".env / 日志 / known_hosts / 私钥 均未被跟踪"
    fi
else
    printf '  \033[33m·\033[0m 非 git 仓库，跳过\n'
fi

# ---------------------------------------------------------------- 结论
if [ "$fail" -eq 0 ]; then
    printf '\n\033[32m结论：未发现敏感信息\033[0m\n\n'
    exit 0
fi
printf '\n\033[31m结论：发现问题，禁止提交\033[0m\n\n'
exit 1
