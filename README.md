# AI_Bot_VPS · 云沙箱保活与零暴露 SSH 中转

[![CI](https://github.com/Angel-Gril/AI_Bot_VPS/actions/workflows/ci.yml/badge.svg)](https://github.com/Angel-Gril/AI_Bot_VPS/actions/workflows/ci.yml)

把"免费/低配云沙箱"当成可远程使用的开发机时，会撞上两类问题：

1. **平台会自动挂起闲置机器** —— 保活要靠平台自己提供的"活动租约 / 任务"接口，光跑进程或开着 SSH 不算活跃。
2. **机器没有公网入口**（NAT / CGNAT / 未备案 / 只给内网 IP）—— 想从任意设备 `ssh` 进去，需要一个有公网 IP 的中转机。

本仓库把这两套机制整理成可复用的脚本与文档，并给出**不新增任何公网端口**的中转架构。

> 所有脚本中的主机、域名、机器 ID 都是占位符。**不要**把自己真实的 key、IP、机器 ID 提交进仓库。

## 组成

```
sesame/        Sprite/Sesame 类容器沙箱：活动租约保活 + 反向 SSH 隧道 + 一键安装恢复 + 自检
instabox/      InstaBox 类云主机：外部租约续期脚本的 retryAfter 补丁
scripts/       仓库工具（敏感信息自查）
tests/         补丁自测（CI 跑）
docs/          平台生命周期实测记录、SSH 中转设计、运维手册
.github/       CI：查密 + shellcheck + POSIX 语法 + 补丁自测
```

## 架构一眼看懂

```
        ┌──────────── 任意设备（笔记本/手机/iPad）────────────┐
        │  ssh -J <user>@<relay> -p 2222 <sandbox_user>@127.0.0.1
        └───────────────────────┬──────────────────────────┘
                                │ 1) 公网 SSH（仅此一跳对外）
                    ┌───────────▼───────────┐
                    │  中转 VPS（有公网 IP）  │
                    │  sshd:22  ← 唯一入口   │
                    │  127.0.0.1:2222 ← 反代 │  ← 只绑回环，公网扫不到
                    └───────────▲───────────┘
                                │ 2) 反向隧道（由沙箱主动拨出）
                    ┌───────────┴───────────┐
                    │   沙箱（NAT 后面）      │
                    │  sshd: 127.0.0.1:22    │  ← 只绑回环
                    │  keepalive: 续租活动   │
                    └───────────────────────┘
```

三个设计要点：

- **沙箱侧 sshd 只监听回环**，机器即使在公网也扫不到
- **中转侧转发端口只绑 `127.0.0.1`**，公网无法直连 2222
- 两把密钥各自被 `authorized_keys` 限死方向（只准 listen / 只准 connect），即使泄露也拿不到 shell

详见 [`docs/03-ssh-relay.md`](docs/03-ssh-relay.md)。

## 快速开始

### 1) 沙箱侧：续租 + 隧道

```bash
# 在沙箱里执行（示例，按需改 .env）
git clone <this-repo> ~/ai-bot-vps && cd ~/ai-bot-vps
cp .env.example .env && vi .env          # 填 RELAY_HOST / RELAY_USER / 端口
bash sesame/install.sh                   # 安装两个常驻服务
```

### 2) 中转侧：加两把受限密钥

见 [`docs/03-ssh-relay.md`](docs/03-ssh-relay.md) 的 `authorized_keys` 模板。

### 3) 客户端：一条命令登录

```sshconfig
Host relay
    HostName <RELAY_HOST>
    User <relay_user>
    IdentityFile ~/.ssh/relay_jump
    IdentitiesOnly yes

Host sandbox
    HostName 127.0.0.1
    Port 2222
    User <sandbox_user>
    ProxyJump relay
    IdentityFile ~/.ssh/sandbox_login
    IdentitiesOnly yes
```

之后 `ssh sandbox` 即可。Windows/macOS/Linux/Termux 自带 OpenSSH 都支持 `-J`，**不需要装任何客户端**。

## 健康自检

```bash
bash sesame/verify.sh          # 0=健康 1=告警 2=异常
bash sesame/verify.sh --json   # 给监控/脚本用
```

检查项：服务是否在跑、租约剩余时长、心跳是否断档、隧道重连次数、`btime` 是否被暂停恢复过、sshd 是否只绑回环。

## 已验证的平台行为（重要，别凭直觉）

| 平台 | 结论 | 文档 |
|---|---|---|
| Sprite/Sesame | 「活跃」= 正在处理 HTTP 请求 **或** detachable session 有产出；跑进程、开 SSH **不算** | [docs/01](docs/01-sesame-lifecycle.md) |
| Sprite/Sesame | 暂停 = 打 checkpoint；恢复后 `btime` 会变但 PID 连续（进程树被原样恢复） | [docs/01](docs/01-sesame-lifecycle.md) |
| InstaBox | 免费档 `maxRunMinutes=480`（连续 8 小时**即使在忙**也会被暂停，租约延长不了） | [docs/02](docs/02-instabox-lifecycle.md) |
| InstaBox | max-run 暂停后有 5–20 分钟冷却，期间所有唤醒方式返回 `409 machine_cooldown` + `retryAfterSeconds` | [docs/02](docs/02-instabox-lifecycle.md) |

## 安全须知

- 本仓库**不含**任何私钥、API key、真实 IP、真实机器 ID。提交前请自查（`bash scripts/secret-scan.sh`），CI 也会强制跑一遍：密钥形态、真实 IP、`.env`/日志是否被跟踪。
- 保活脚本会在平台侧产生"长期活跃"的行为特征。用之前请确认你遵守目标平台的服务条款。
- 中转机是唯一公网入口，务必：禁密码登录、禁 root 密码、装 fail2ban、只放行必要端口。

## License

MIT，见 [LICENSE](LICENSE)。
