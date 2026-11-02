#!/usr/bin/env python3
"""patch_retry_after.py 的自测（CI 里跑）。

思路：不维护一份会与上游脱节的静态 fixture，而是直接拿补丁模块里的
OLD_* 常量去拼一个"上游形状"的最小脚本，因此一旦补丁的匹配串与上游
结构不一致，这里会立刻失败。

覆盖：
  1. 正常打补丁 → 成功且 sh -n 通过
  2. 再打一次 → 幂等，内容不变
  3. --dry-run → 不写入
  4. 结构不匹配 → 返回非 0，不损坏文件
"""

import io
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "instabox"))

import patch_retry_after as P  # noqa: E402

HEADER = """#!/bin/sh
set -u
TTL=${INSTABOX_LEASE_TTL:-900}
RENEW=${INSTABOX_RENEW_EVERY:-$((TTL * 3 / 5))}
LEASE=keepalive
AUTO_RESUME=1
HTTP_CODE=
HTTP_BODY=

"""

BODY = """log() { printf '%s\\n' "$*"; }

is_not_running() {
\t[ "$HTTP_CODE" = "409" ] || return 1
\tprintf '%s' "$HTTP_BODY" | grep -Eqi 'not_running|suspended|stopped'
}

renew_one() {
\tif http PUT "/v1/machines/$1/activity-leases/$LEASE" "{\\"ttlSeconds\\":$TTL}"; then
\t\tlog "续租 ok"
\t\treturn 0
\tfi
__OLD_FAIL__

each_key() { "$1"; }
each_machine() { "$1" m_fixture key; }
renew_round() { each_machine renew_one; }

__OLD_RENEW__

run_watch() {
\tlog "watch"
__OLD_LOOP__
}
"""


def build_fixture(path):
    """按上游形状拼一个最小脚本（OLD_* 直接取自补丁模块）"""
    body = BODY.replace("__OLD_FAIL__", P.OLD_FAIL)
    body = body.replace("__OLD_RENEW__", P.OLD_RENEW)
    body = body.replace("__OLD_LOOP__", P.OLD_LOOP)
    io.open(path, "w", encoding="utf-8", newline="").write(HEADER + P.DOC_ANCHOR + "\n\n" + body)


def sh_syntax_ok(path):
    r = subprocess.run(["sh", "-n", path], capture_output=True, text=True)
    if r.returncode != 0:
        print("sh -n 失败:\n" + r.stderr)
    return r.returncode == 0


def run(args):
    return subprocess.run(
        [sys.executable, os.path.join(ROOT, "instabox", "patch_retry_after.py")] + args,
        capture_output=True,
        text=True,
    )


def main():
    failures = []

    with tempfile.TemporaryDirectory() as td:
        # ---- 1) 正常打补丁
        f1 = os.path.join(td, "k1.sh")
        build_fixture(f1)
        if not sh_syntax_ok(f1):
            failures.append("fixture 本身语法就不对")
        r = run(["--path", f1])
        if r.returncode != 0:
            failures.append(f"打补丁失败 rc={r.returncode}: {r.stderr.strip()}")
        patched = io.open(f1, encoding="utf-8").read()
        for token in ("WAIT_NEXT", "retry_after_seconds", "INSTABOX_WAIT_MAX"):
            if token not in patched:
                failures.append(f"打补丁后缺少 {token}")
        if not sh_syntax_ok(f1):
            failures.append("打补丁后语法不通过")

        # ---- 2) 幂等
        r2 = run(["--path", f1])
        if r2.returncode != 0 or "已经打过补丁" not in r2.stdout:
            failures.append(f"二次打补丁不是幂等：rc={r2.returncode} out={r2.stdout.strip()}")
        again = io.open(f1, encoding="utf-8").read()
        if again != patched:
            failures.append("二次打补丁改变了文件内容")

        # ---- 3) --dry-run 不写入
        f2 = os.path.join(td, "k2.sh")
        build_fixture(f2)
        before = io.open(f2, encoding="utf-8").read()
        r3 = run(["--path", f2, "--dry-run"])
        after = io.open(f2, encoding="utf-8").read()
        if r3.returncode != 0:
            failures.append(f"--dry-run 返回 {r3.returncode}")
        if before != after:
            failures.append("--dry-run 竟然写了文件")

        # ---- 4) 结构不匹配要安全失败
        f3 = os.path.join(td, "k3.sh")
        io.open(f3, "w", encoding="utf-8").write("#!/bin/sh\necho hello\n")
        before3 = io.open(f3, encoding="utf-8").read()
        r4 = run(["--path", f3])
        if r4.returncode == 0:
            failures.append("结构不匹配时竟然返回成功")
        if io.open(f3, encoding="utf-8").read() != before3:
            failures.append("失败时不应修改文件")

    if failures:
        print("\n自测失败：")
        for f in failures:
            print("  - " + f)
        return 1

    print("patch_retry_after 自测全部通过（打补丁/幂等/dry-run/安全失败）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
