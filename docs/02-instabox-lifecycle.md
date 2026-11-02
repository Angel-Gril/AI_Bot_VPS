# InstaBox：生命周期与保活实测记录

免费档云 microVM。结论来自官方文档 + 三天多的运行日志分析，机器 ID 已脱敏。

## 1. 规格与限额（免费档）

| 项 | 值 |
|---|---|
| 机器规格 | 4 vCPU / 8 GiB / 20 GiB 持久盘（免费档固定，唯一可选规格） |
| 机器数量 | 1 台（paused/stopped 也算占位） |
| 虚拟化 | Firecracker microVM，Linux `6.18.x-instabox` |
| 闲置暂停 | **30 分钟，固定** |
| **最长连续运行 `maxRunMinutes`** | **480 分钟，固定，只有管理员能改** |
| 发起操作速率 | 3 次/分钟（create/start/resume/wake；**租约续期不在此列**） |
| 出网流量 | 100 GiB/月 |

## 2. 两种暂停，性质完全不同

### ① 闲置暂停（idle pause）
只要"有活"就不会发生。文档定义 busy：

> idle 指的是没有 coding agent 在工作、没有终端或 SSH 流量、没有 CPU 负载；exec、读文件、访问公开端口、**进行中的 task lease** 都算 busy。信号缺失或不明确时按 busy 处理。

→ 可以用**活动租约**长期避免。

### ② max-run 暂停
> `maxRunMinutes` pauses a machine after that many minutes of continuous running, **even while it is busy; activity and leases do not extend it.**

到点**无论多忙都暂停**，租约、活动、心跳统统无效。免费档固定 480 分钟。

→ **这个只能靠"冷却结束后尽快恢复"来缩短影响，无法阻止。**

## 3. 冷却期的行为

max-run 暂停后进入冷却（文档称 5–20 分钟 = 5 + 随机 0~15，避免同时到期的机器一起恢复）。期间**所有唤醒方式**都被拒：

```
HTTP 409
{"error":{"code":"machine_cooldown",
          "message":"machine is cooling down until 2026-xx-xxTxx:xx:xxZ",
          "retryable":true,
          "retryAfterSeconds":5756,
          "docs_url":"...#machine-cooldown"}}
```

同时会带 `Retry-After` 响应头。官方要求：**等 `retryAfterSeconds` 再重试**。

冷却不受"停/暂停/改配置"影响，不能提前结束。

## 4. 实测：8 小时周期坐实了

连续 93 小时的续租日志（每 540 秒一次）：

```
中断窗口（连续失败段）
10-30 00:45 → 00:54   9.1 分
10-30 09:00 → 09:09   9.1 分
10-30 17:15 → 17:24   9.1 分
10-31 01:30 → 01:48  18.1 分
10-31 09:55 → 10:13  18.1 分
10-31 18:19 → 18:28   9.1 分
11-01 02:34 → 02:43   9.1 分
11-01 10:49 → 10:58   9.1 分
11-01 19:05 → 19:14   9.2 分
11-02 03:20 → 04:23  63.1 分   ← 超预期
11-02 12:29 → 14:35 126.2 分   ← 超预期
```

各次开始时刻的间隔：**8h15 / 8h15 / 8h15 / 8h25 / 8h24 / 8h15 / 8h15 / 8h16 / 8h15** —— 与 `480 分钟 + 冷却 + 检测延迟` 完全吻合。

`GET /v1/machines/<id>` 也确认了 `maxRunMinutes = 480`、`autoSuspendAfterSeconds = 1800`。

## 5. 两个未解之谜

1. **冷却时长与文档不符**：文档写 5–20 分钟，但实测出现过 63 分钟和 126 分钟。第 11 次事件里，`retryAfterSeconds` 从 5756 一路递减到 354，说明 `cooldownUntil` 是**固定**的（约 2 小时），不是反复重置。可能是免费档实际策略更长，或文档过时。**建议下次出现 409 时立刻记下 `cooldownUntil - now`，多攒几次就有答案。**
2. **短中断正好等于一个续租周期**：9.1 分钟 ≈ 540 秒续租间隔 + 少量开销。这说明"冷却结束后要等下一次续租才发现" —— 这正是把续租间隔改小的收益来源。

## 6. 由此得出的参数选择

| 参数 | 值 | 理由 |
|---|---|---|
| `INSTABOX_LEASE_TTL` | **900s** | TTL 是"保活挂掉后多久机器才被闲置暂停"的容忍窗口，越长越安全 |
| `INSTABOX_RENEW_EVERY` | **180s** | TTL 窗口内能容忍 4 次连续失败；恢复检测粒度从 9 分钟降到 3 分钟 |
| 失败处理 | 按 `retryAfterSeconds` 等待 | 冷却一结束立刻恢复，而不是白等一个周期 |

**别把 TTL 一起改短** —— 那是拿"容忍窗口"换"检测速度"，方向反了。

## 7. 租约接口

```bash
# 续期 / 新建（把 ttlSeconds 放在 body 里，范围 30–3600）
curl -X PUT "https://api.<provider>/v1/machines/<machine_id>/activity-leases/<lease_name>" \
     -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
     -d '{"ttlSeconds":900}'

# 释放（想让机器恢复正常闲置挂起时用）
curl -X DELETE ".../activity-leases/<lease_name>" -H "X-API-Key: $KEY"
```

注意：租约接口只认**机器 id**（传名字会 400）。机器被挂起后，续租会返回 `409 machine_not_running`，需要先 resume/start 再续租——这就是保活脚本里 `AUTO_RESUME` 分支的作用。
