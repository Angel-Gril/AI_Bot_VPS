# Sprite / Sesame 容器沙箱：生命周期实测记录

以下结论来自对真实容器的观测（读 `/proc`、平台自带文档、API 探测），不是推测。所有 ID 已脱敏。

## 1. 什么算「活跃」

平台自带文档（`/.sprite/docs/agent-context.md`）原文：

> - Sprites run while **actively servicing HTTP requests**
> - Sprites run while **detachable sessions are generating output**
> - When neither condition is true, sprites pause
> - Sprites **may remain paused or be fully stopped at any time**

也就是说：

| 行为 | 算活跃？ |
|---|---|
| 常驻进程在跑（含 `services`） | ❌ |
| 开着 SSH 会话、有网络流量 | ❌ |
| HTTP 服务收到请求 | ✅ |
| detachable session 有产出（对应 `/v1/tasks` 的活动租约） | ✅ |

实测佐证：有一段时间每隔约 1 分钟用 SSH 进去跑命令，最后一次活跃后 **≤5 分钟**机器就进入暂停；另一次是 19 分钟。**"30 分钟闲置"这个广为流传的数字并不可靠**，别拿它当设计依据。

## 2. 活动租约 API（未在文档中列出，实测可用）

走本机 unix socket：`/.sprite/api.sock`，用 `sprite-env curl` 包装即可。

| 操作 | 请求 | 结果 |
|---|---|---|
| 新建 | `POST /v1/tasks` `{"name":"x","expire":"2m"}` | `201` + `{name, started_at, expires_at}` |
| 重复新建 | 同上，同名 | **`409` `task "x" already exists`** |
| **续期（推荐）** | `PUT /v1/tasks/x` `{"expire":"2m"}` | `200`，`expires_at` 前移 → **upsert** |
| 续期不存在的名字 | `PUT /v1/tasks/brand-new` | `200`，直接创建 → 确认 upsert 语义 |
| 列表 | `GET /v1/tasks` | `{"tasks":[{name, started_at, expires_at}]}` |
| 删除 | `DELETE /v1/tasks/x` | `204` |

字段细节：

- `expire` **必填**，缺了直接 `400 expire is required`
- 支持秒数或时长字符串（`"2m"` / `"300"`），**上限 3600 秒**，超出 `400 exceeds maximum 3600 seconds`
- `PUT` 会**同时重置 `started_at`**，不是只延长 `expires_at`

> 踩坑提醒：**`POST` 只能新建，重复调用全是 409。** 拿 POST 当续期用，第一次成功、之后全被拒，租约过期机器照样被挂起——而且是静默失败（如果没检查 HTTP 码）。

## 3. 暂停 = 打 checkpoint，恢复会换内核

观测到的特征组合，很容易被误判成"重启"：

| 现象 | 暂停/恢复后 | 说明 |
|---|---|---|
| `/proc/stat` 的 `btime` | **变化**（一次观测从 06:52 跳到 10:48） | 恢复后是**新内核** |
| 进程 PID | **不变**（`sshd` 1429、`tailscaled` 293 前后一致） | 进程树被原样恢复 |
| `/proc/uptime` | 归零重算 | 因为内核换了 |
| `ps` 的 `STARTED` | 全部被"平移"到新 btime 之后 | 由 `btime + starttime_ticks` 算出，tick 值保留 |
| `wtmp` / 重启记录 | **空** | 没有真正的 reboot 记录 |
| `checkpoints list` | 出现新的 `Current` / `vN` | 暂停时打快照 |

所以判断"是不是被暂停过"，**不能看 `last reboot`，也不能看进程 PID 是否变了**，要看 `btime` 是否跳变。

另一个副作用：**恢复后所有 TCP 连接都是僵的**。进程还活着、socket 已经死了。隧道/长连接的守护参数必须够狠：

```sh
-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes
```

默认 30s×3 会白卡 90 秒；15s×3 = 45 秒内判定死链。

## 4. 服务托管：没有 systemd

`PID 1` 是 `tini`，`systemctl is-system-running` 返回 `offline`。用平台自己的服务管理器：

```bash
sprite-env services create <名字> --cmd /usr/local/bin/xxx.sh [--args a,b] [--env K=V] [--dir /path]
sprite-env services list|get|restart|stop|delete <名字>
```

实测到的硬约束：

| 项 | 实测结果 |
|---|---|
| `--cmd` 语义 | **只接受可执行文件路径，不经过 shell**。传 `'id -un > /tmp/a'` 会报 `executable file ... not found` |
| 运行身份 | **uid=1001（普通用户）**，不是 root |
| 崩溃后 | 平台自动重启（秒级），`restart_count` 自增 |
| 启动时 | 服务随机器启动自动恢复 |
| 日志 | 平台自动收集 stdout/stderr 到 `/.sprite/logs/services/<名字>.log` |
| 因此 | **脚本不需要自己写 `/var/log`**（那个目录普通用户写不进去，会静默丢失） |

## 5. 网络策略：按 DNS 过滤

文档原文：

> - Denied domains: DNS returns REFUSED
> - **Raw IP connections: Blocked unless the IP was resolved from an allowed domain**
> - Private IPs: Always blocked
> - Policy changes reload automatically and **terminate existing connections**

含义：出站连**裸 IP** 在策略启用后会被拦。要长期稳定地连中转机，最好用域名解析（并确保该域名在允许列表里）；策略**只能在容器外**通过 API 修改。

当前策略可以在容器里查看：`/.sprite/policy/network.json`（不存在或空 = 未启用过滤）。

## 6. checkpoint 只保存可写层

```
overlay lowerdir = 基础镜像层
        upperdir = /mnt/user-data/root-upper/upper   ← 快照只抓这一层
```

所以"重建镜像"和"恢复快照"是两件事：前者丢 overlay，后者丢 base 的更新。恢复链（`sesame/install.sh`）要覆盖前者。
