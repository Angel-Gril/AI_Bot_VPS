#!/usr/bin/env python3
"""给 instabox-keepalive 打个补丁：失败时按服务端给的 retryAfterSeconds 等待。

适用脚本：https://github.com/pingmike2/instabox-keepalive 的 keepalive.sh
默认路径：/root/instabox-keepalive/keepalive.sh（可用 --path 覆盖）

背景
    max-run 暂停会进入冷却期，期间所有唤醒/续租都返回
        409 {"error":{"code":"machine_cooldown","retryAfterSeconds":N}}
    上游脚本按固定间隔（默认 TTL 的 3/5）盲打，冷却结束时要多等一个完整周期才能恢复，
    冷却期间还会反复打无效请求。官方文档要求“等 retryAfterSeconds 再重试”。

改动
    1. 新增 retry_after_seconds()，从响应体提取倒计时
    2. renew_one() 失败分支把倒计时记进 WAIT_NEXT（本轮最早可重试时间）
    3. watch 循环若 WAIT_NEXT>0 就按它 sleep，否则用原固定间隔
    4. 新增 WAIT_MIN / WAIT_MAX 上下界（默认 10 / 7200 秒）

用法
    sudo python3 patch_retry_after.py              # 打补丁
    sudo python3 patch_retry_after.py --path /x    # 指定脚本路径
    sudo python3 patch_retry_after.py --dry-run    # 只看会不会改

幂等：检测到已打过（存在 WAIT_NEXT）直接退出。
"""

import argparse
import io
import os
import shutil
import sys
import time

DEFAULT_PATH = "/root/instabox-keepalive/keepalive.sh"

HELPER = '''WAIT_NEXT=0

# 从响应体里取服务端给的冷却倒计时（machine_cooldown 会带 retryAfterSeconds）
retry_after_seconds() {
	secs=$(printf '%s' "$1" | sed -n 's/.*"retryAfterSeconds"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' | head -n 1)
	case "$secs" in ''|*[!0-9]*) echo 0 ;; *) echo "$secs" ;; esac
}

'''

OLD_FAIL = '''\tlog "续租失败 $2/$LEASE HTTP $HTTP_CODE: $HTTP_BODY"
\treturn 1
}'''

NEW_FAIL = '''\tlog "续租失败 $2/$LEASE HTTP $HTTP_CODE: $HTTP_BODY"
\tra=$(retry_after_seconds "$HTTP_BODY")
\tif [ "$ra" -gt 0 ]; then
\t\tlo=${INSTABOX_WAIT_MIN:-10}
\t\thi=${INSTABOX_WAIT_MAX:-7200}
\t\t[ "$ra" -lt "$lo" ] && ra=$lo
\t\t[ "$ra" -gt "$hi" ] && ra=$hi
\t\t[ "$ra" -gt "$WAIT_NEXT" ] && WAIT_NEXT=$ra
\t\tlog "  → 服务端要求 ${ra}s 后可重试（倒计时优先于固定间隔）"
\tfi
\treturn 1
}'''

OLD_RENEW = "renew() { each_key renew_round; }"
NEW_RENEW = "renew() { WAIT_NEXT=0; each_key renew_round; }"

OLD_LOOP = '''\twhile :; do
\t\trenew || log "这一轮有失败，下一轮再试"
\t\tsleep "$RENEW"
\tdone'''

NEW_LOOP = '''\twhile :; do
\t\trenew || log "这一轮有失败，下一轮再试"
\t\tw=$RENEW
\t\tif [ "$WAIT_NEXT" -gt 0 ]; then
\t\t\tw=$WAIT_NEXT
\t\t\tlog "按服务端倒计时等待 ${w}s"
\t\tfi
\t\tWAIT_NEXT=0
\t\tsleep "$w"
\tdone'''

DOC_ANCHOR = "#     INSTABOX_API_URL       API 地址（默认 https://api.instabox.sh）"
DOC_NEW = DOC_ANCHOR + """
#     INSTABOX_WAIT_MIN/MAX  失败倒计时的下/上界秒数（默认 10 / 7200）"""


def patch(path: str, dry_run: bool) -> int:
    if not os.path.isfile(path):
        print(f"错误: 找不到 {path}", file=sys.stderr)
        return 2

    src = io.open(path, encoding="utf-8").read()
    if "WAIT_NEXT" in src:
        print("已经打过补丁，跳过")
        return 0

    steps = []
    anchor = "is_not_running() {"
    if src.count(anchor) != 1:
        print("错误: 找不到唯一的 is_not_running()，脚本版本可能不同", file=sys.stderr)
        return 3
    src = src.replace(anchor, HELPER + anchor, 1)
    steps.append("插入 retry_after_seconds()")

    for old, new, label in (
        (OLD_FAIL, NEW_FAIL, "renew_one 失败分支"),
        (OLD_RENEW, NEW_RENEW, "renew() 每轮重置"),
        (OLD_LOOP, NEW_LOOP, "watch 循环按倒计时 sleep"),
        (DOC_ANCHOR, DOC_NEW, "文档注释"),
    ):
        if src.count(old) != 1:
            print(f"错误: 无法定位「{label}」，脚本版本可能不同", file=sys.stderr)
            return 3
        src = src.replace(old, new, 1)
        steps.append(label)

    print("将执行：")
    for s in steps:
        print(f"  - {s}")

    if dry_run:
        print("dry-run，未写入")
        return 0

    bak = path + ".bak." + time.strftime("%Y%m%dT%H%M%SZ")
    shutil.copy2(path, bak)
    io.open(path, "w", encoding="utf-8", newline="").write(src)
    os.chmod(path, 0o755)
    print(f"已写入，备份: {bak}")
    print("下一步：sh -n " + path + " && systemctl restart instabox-keepalive")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="给 instabox-keepalive 打 retryAfter 补丁")
    ap.add_argument("--path", default=DEFAULT_PATH, help="keepalive.sh 路径")
    ap.add_argument("--dry-run", action="store_true", help="只检查不写入")
    a = ap.parse_args()
    return patch(a.path, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
