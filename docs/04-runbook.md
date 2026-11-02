# 运维手册

## 1. 日常自检（一条命令）

```bash
bash sesame/verify.sh          # 0=健康 1=告警 2=异常
bash sesame/verify.sh --quiet  # 只输出有问题的行
bash sesame/verify.sh --json   # 机器可读，便于接监控
```

它会依次检查：服务状态、租约剩余时长、心跳是否断档、隧道重连次数、`btime` 是否被暂停恢复过、sshd 是否只绑回环。

手动展开版（需要自己看清数字时）：

```bash
# 沙箱侧：服务、租约、心跳缺口、隧道重连次数
sprite-env services list
sprite-env curl -s /v1/tasks; echo
awk '{print $1}' ~/.local/state/sesame-keepalive/keepalive.log | grep '^20' \
  | while read t; do date -d "$t" +%s; done \
  | awk 'NR>1{if($1-p>90) print "缺口 "($1-p)"s"; p=$1}'
grep -c 'ssh 退出' ~/.local/state/sesame-keepalive/tunnel.log
```

判读标准：

| 指标 | 健康值 |
|---|---|
| 服务状态 | 两个都 `running`，PID 长时间不变 |
| `expires_at` | 恒比当前时间晚一个 TTL 左右 |
| 心跳缺口 | **无**（> 1.5×间隔即为异常） |
| 隧道 "ssh 退出" 计数 | 只在手动重启时增加；自然增长说明链路不稳 |
| `btime` | 与上次记录一致；跳变 = 被暂停恢复过 |

## 2. 判断"是不是被暂停过"

**不要看 `last reboot`，也不要看 PID。**

```bash
awk '/btime/{print $2}' /proc/stat    # 变了 = 恢复过（内核换了）
cat /proc/uptime                      # 归零 = 同上
```

暂停恢复的典型特征组合：`btime` 变 + PID 不变 + `wtmp` 空（详见 [01-sesame-lifecycle.md](01-sesame-lifecycle.md)）。

## 3. 沙箱重建后的恢复（三步）

```bash
# ① 从平台控制台进入沙箱（此时没有任何网络入口，只能靠带外通道）
git clone <this-repo> ~/ai-bot-vps && cd ~/ai-bot-vps
cp .env.example .env && vi .env      # 填 RELAY_HOST / 指纹 / 端口
bash sesame/install.sh
```

`install.sh` 结束时会把**新生成的隧道公钥**打印成一整行（含 `command=` / `restrict` / `permitlisten=` 前缀）。

```bash
# ② 在中转机上把那一行追加进 authority（可直接从本机执行）
ssh root@<RELAY_HOST> "echo '<粘贴 install.sh 输出的那一整行>' >> /root/.ssh/authorized_keys"
```

```bash
# ③ 验证
ssh -J <relay_user>@<RELAY_HOST> -p 2222 <sandbox_user>@127.0.0.1 'echo ok'
```

> **为什么必须重加**：重建后 `~/.ssh/tunnel` 是新的密钥对，中转机上旧的公钥已经没用了。
> 这也是为什么 `install.sh` 会把"待添加的那一行"直接打印出来，而不是让你自己拼。

## 4. 常见故障速查

| 症状 | 先查这个 | 再查这个 |
|---|---|---|
| 两条入口都不通 | 沙箱是否被暂停（`btime` / 平台控制台） | 平台侧是否彻底停机 |
| 只有隧道不通 | `ss -ltn \| grep 2222`（中转机） | 沙箱隧道日志最后 20 行 |
| 隧道通了但登不上 | 中转 `authorized_keys` 的 `permitopen` 字面量 | 沙箱 `sshd` 是否仍绑 `127.0.0.1:22` |
| 保活不续期 | `sprite-env curl -s /v1/tasks` 看 `expires_at` | 日志里 HTTP 码（`sprite-env curl` 带 fail 语义，4xx 会返回非零） |
| 服务显示 running 但进程不在 | `sprite-env services get <name>` 的 pid vs `ps` | 直接 `restart` 让平台重建 |

## 5. 回滚

```bash
# 脚本回滚（install.sh 每次都会留 .bak）
ls -t /usr/local/bin/sesame-*.sh.bak.* | head
cp /usr/local/bin/sesame-tunnel.sh.bak.<时间戳> /usr/local/bin/sesame-tunnel.sh
sprite-env services restart tunnel

# 参数回滚：改回 .env 后重启服务
sprite-env services restart keepalive
```

## 6. 提交前查密（本仓库的硬要求）

```bash
bash scripts/secret-scan.sh     # 与 CI 里跑的是同一个脚本
```

它检查三类东西，任一类发现问题就退出 1：

| 检查 | 内容 |
|---|---|
| A | 私钥 / 令牌形态（`BEGIN PRIVATE KEY`、`ghp_`、`sk-`、`ibk_`、`AKIA`…）|
| B | 真实 IP（只允许回环 `127.0.0.1` 与 RFC 5737 文档段）|
| C | `.env` / 日志 / `known_hosts` / 私钥是否被 git 跟踪 |

更底层的手写命令（想自己看时用）：

```bash
# 1) 常见密钥形态
grep -rInE '(BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519) AAAA[^"]{40,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|ibk_[A-Za-z0-9]{10,})' . \
  --exclude-dir=.git | grep -v '\.env\.example'

# 2) 真实 IP / 机器 ID / 内部域名
grep -rInE '([0-9]{1,3}\.){3}[0-9]{1,3}|\bm_[a-z0-9]{20,}\b|\.ts\.net|sprites\.app' . \
  --exclude-dir=.git

# 3) 确认 .env 与日志没被跟踪
git ls-files | grep -E '(^|/)\.env$|\.log$|known_hosts|\.pem$|\.key$'
```

三条都必须**无输出**（或只有文档里的示例占位符）。示例占位符统一用文档保留地址：

- IPv4：`203.0.113.0/24`、`198.51.100.0/24`、`192.0.2.0/24`（RFC 5737）
- 域名：`example.com`
- 指纹：`SHA256:AAAA...`（全 A 占位）

## 7. 安全基线（中转机）

```bash
# SSH 只留公钥
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3

# 装 fail2ban（公网 22 每天被扫几百次是常态）
apt install -y fail2ban && systemctl enable --now fail2ban

# 确认没有多余公网端口
ss -ltn | awk 'NR>1 && $4 !~ /^127\./ {print}'
```

## 8. 已知限制

- **无法阻止平台的 max-run 暂停**（免费档固定 480 分钟），只能把恢复时间压到最短
- 机器一旦被暂停，**没有任何远程手段能唤醒**，必须走平台控制台/客户端
- 中转机是唯一公网入口，是单点：它挂了就全挂（可再挂一台做备份，但客户端配置要改）
