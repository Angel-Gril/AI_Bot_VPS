# InstaBox 保活

InstaBox 类是「Firecracker microVM 云主机」，闲置会被挂起，免费档还有**最长连续运行时间**限制。保活必须从**机器外部**打进来（机器被挂起后，里面的定时器也冻结了）。

## 机制（官方文档摘要）

| 项 | 免费档 | 付费档 |
|---|---|---|
| 闲置暂停 | 30 分钟，固定 | 5–30 分钟可调，或关闭 |
| **最长连续运行 `maxRunMinutes`** | **480 分钟（8 小时），固定** | 默认无限，可自选 |
| max-run 后的冷却 | 5–20 分钟（5 + 随机 0~15） | 同 |

两个关键细节：

- `maxRunMinutes` 到点**即使在忙也会暂停**，`activity` 和 `lease` 都延长不了它 —— 这意味着**保活方案无法阻止 8 小时一次的暂停**，只能做到"冷却一结束立刻恢复"。
- 冷却期间**所有唤醒方式**（exec / SSH / 公开 URL / wake / resume / start）全部返回：

  ```
  HTTP 409  {"error":{"code":"machine_cooldown","retryable":true,
                      "retryAfterSeconds":5756,  ...}}
  ```

  官方文档明确要求：**等 `retryAfterSeconds` 秒再重试**。

## 安装

上游有一个现成的脚本，本仓库不重复分发它（尊重原作者），只提供**补丁**：

```bash
# 1) 装上游脚本（详见上游 README）
#    https://github.com/pingmike2/instabox-keepalive

# 2) 打补丁：让它在冷却期按 retryAfterSeconds 等待，而不是固定间隔盲打
python3 patch_retry_after.py

# 3) 重启服务
systemctl restart instabox-keepalive
```

## 补丁做了什么

| 改动 | 原因 |
|---|---|
| 解析响应体里的 `retryAfterSeconds`，本轮按它 sleep | 上游按固定间隔（默认 TTL 的 3/5）盲打，冷却结束时最多白白多等一个周期；冷却两小时会打十几次无效请求 |
| 新增 `WAIT_MIN` / `WAIT_MAX`（默认 10 / 7200 秒） | 防止服务端返回 0 或离谱值时把自己卡死或打爆 |
| 每轮重置等待值 | 避免一次失败影响后续所有轮次 |

补丁是幂等的：检测到已打过会直接退出。

## 建议的 `.env`

```conf
# 保持 TTL 较长 = 保活失效后的容忍窗口更长
INSTABOX_LEASE_TTL=900
# 续租更密 = 恢复更快，且 TTL 窗口内可容忍更多次连续失败
INSTABOX_RENEW_EVERY=180
```

> 注意别把 TTL 一起改短：TTL 决定"保活挂掉后多久机器会被闲置暂停"，缩短它是自伤。
> 想提高抗故障能力，应该减 `RENEW`、保 `TTL`。

## 现实预期

即使补丁到位，免费档仍有：

```
每 8 小时：暂停 1 次（max-run）+ 冷却 5~20 分钟（实测个别场景更长）
```

所以需要接受"每天约 3 次、每次几分钟不可用"。要彻底消除，只能升级付费档把 `maxRunMinutes` 设为 `-1`。

详见 [../docs/02-instabox-lifecycle.md](../docs/02-instabox-lifecycle.md)。
