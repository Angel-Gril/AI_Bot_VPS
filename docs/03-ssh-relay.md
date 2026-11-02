# 零暴露 SSH 中转：设计、配置与踩坑

目标：**沙箱在 NAT 后面、没有公网 IP、还不想开任何公网端口**，但要求"任何设备一条 `ssh` 就能进"。

## 1. 拓扑

```
客户端                     中转 VPS（有公网 IP）              沙箱（NAT 后面）
  │                              │                              │
  ├─ ① sshd:22（唯一公网端口）──▶│                              │
  │                              ├─ ② 127.0.0.1:2222 ────────▶ │ sshd 127.0.0.1:22
  │                              │   （反向隧道出口，只绑回环）    │ （只绑回环）
  │                              │        ▲                     │
  │                              │        └── ③ 沙箱主动拨出 ssh -R
```

三处"只绑回环"是关键：沙箱的 sshd、中转的 2222、以及中转 sshd 本身不需要额外开放端口。

## 2. 两把密钥，各自被限死一个方向

中转机的 `~/.ssh/authorized_keys`：

```
# ① 沙箱用：只准"监听" 127.0.0.1:2222，拿不到 shell
command="/bin/false",restrict,port-forwarding,permitlisten="127.0.0.1:2222" <TUNNEL_PUBKEY> tunnel@sandbox

# ② 客户端用：只准"连接" 127.0.0.1:2222，拿不到 shell
command="/bin/false",restrict,port-forwarding,permitopen="127.0.0.1:2222" <JUMP_PUBKEY> jump@devices
```

逐项解释：

| 选项 | 作用 |
|---|---|
| `command="/bin/false"` | 会话类请求（要 shell、要执行命令）直接执行 `/bin/false` 失败 |
| `restrict` | 关掉 pty / agent 转发 / X11 / `~/.ssh/rc` 等一切 |
| `port-forwarding` | **必须显式加回来**——`restrict` 会把转发一起关掉，漏了它 `-R`/`-J` 直接不通 |
| `permitlisten=` | 隧道侧只准绑这个地址，别的绑定请求一律拒绝 |
| `permitopen=` | 跳板侧只准连这个地址，等于把它钉死成"只能进沙箱的通道" |

这样即使任一把私钥泄露，攻击者也只能在 `127.0.0.1:2222` 上做这件事，**拿不到中转机 shell，也去不了别的地方**。

## 3. 踩坑：字符串是逐字匹配的

`permitopen` / `permitlisten` **不做 DNS 解析、不做规范化**，是拿请求里的字面量去比。所以：

| 写法 | 结果 |
|---|---|
| 限制写 `permitopen="127.0.0.1:2222"`，客户端却连 `localhost:2222` | ❌ 拒绝（`localhost` ≠ `127.0.0.1`） |
| `-R 2222:127.0.0.1:22`（省略绑定地址） | ⚠️ 客户端默认发 `localhost`，和限制对不上 |
| `-R 127.0.0.1:2222:127.0.0.1:22` + `permitlisten="127.0.0.1:2222"` | ✅ 两边字面量一致 |

**结论：两端统一写 `127.0.0.1`，并且 `-R` 永远写全 `绑定地址:端口`。**

顺带：`GatewayPorts` 保持默认 `no` 就好，它本来就会把 `-R` 绑到回环，不需要改。

## 4. 主机键 pinning（防中间人）

隧道脚本启动前做三重检查，任一不过就拒绝启动：

```sh
[ -r "$TUNNEL_KEY" ]     || exit 1     # 私钥在
[ -r "$KNOWN_HOSTS" ]    || exit 1     # known_hosts 在
ssh-keygen -F "$RELAY_HOST" -f "$KNOWN_HOSTS" >/dev/null || exit 1   # 主机键已钉住
```

连接参数：

```sh
ssh -F /dev/null -N -T \
    -o StrictHostKeyChecking=yes \         # 不对就断，绝不 accept-new
    -o UserKnownHostsFile=$KNOWN_HOSTS \
    -o ExitOnForwardFailure=yes \          # 绑定失败立刻退出，别假装连上了
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \   # 45s 判定死链
    -i $TUNNEL_KEY -R 127.0.0.1:2222:127.0.0.1:22 \
    $RELAY_USER@$RELAY_HOST
```

`install.sh` 在写 `known_hosts` 时支持传入**已核实过的指纹**：不匹配就中止，避免"ssh-keyscan 拿到什么就信什么"。

> 为什么必须 pinning：如果只靠 DNS 判定对面是谁，改一条 A 记录就能把人导到恶意机器上。pinning 之后，DNS 投毒只会导致**连不上**，而不是**连错**。

## 5. 客户端配置

```sshconfig
Host relay
    HostName 203.0.113.10
    User tunnel
    IdentityFile ~/.ssh/relay_jump
    IdentitiesOnly yes

Host sandbox
    HostName 127.0.0.1
    Port 2222
    User sandbox_user
    ProxyJump relay
    IdentityFile ~/.ssh/sandbox_login
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

- `HostName 127.0.0.1` 不需要改：`-J` 是在**跳板机上**解析并连接最终目标的
- 跳板的 `IdentityFile` 由 `Host relay` 段提供，最终目标的身份用 `Host sandbox` 段，两把密钥互不干扰

**Windows 注意**：Win32-OpenSSH **不支持 `ControlMaster`**（会报 `getsockname failed: Not a socket`）。跨平台通用的配置里别写 `ControlMaster` / `ControlPath`，那两行只在 Linux/macOS/Termux 有效。

## 6. 故障模式

| 现象 | 原因 | 处置 |
|---|---|---|
| 客户端 `Connection refused` on 2222 | 隧道没起来（`-R` 未建立） | 看沙箱侧隧道日志；确认中转 `ss -ltn \| grep 2222` |
| 客户端卡在握手 | 沙箱被平台挂起（进程冻结，socket 不响应） | 先唤醒沙箱；这是"机器睡了"而非网络问题 |
| 隧道反复重连 | 沙箱经历过 checkpoint 恢复，TCP 变僵 | 属正常，`ServerAlive 15×3` 会在 45s 内重连 |
| `Permission denied (publickey)` | 公钥没加进中转 / `permitopen` 字符串不匹配 | 对照第 3 节检查字面量 |
| 连上但立刻断开、无 shell | `command="/bin/false"` 生效了 | 这是设计如此；要 shell 请登沙箱，不要登跳板 |

## 7. 隐私边界

- **私钥永远不离开各自机器**：沙箱的隧道私钥只在沙箱，客户端的跳板私钥只在客户端
- 中转机只持有**公钥**，且被 `command=/bin/false` + `permitopen/listen` 限死
- 本仓库不记录任何真实主机名、IP、机器 ID
