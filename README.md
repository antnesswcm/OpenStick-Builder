# SP970 Alpine 固件刷机指南（从原厂 Android 首次刷机）

> 适用对象：原厂 Android 的 SP970 4G 随身 WiFi，首次刷入 Alpine Linux v5 固件。
> 前置条件：Windows PC + USB 数据线 + fastboot 工具 + GitHub 构建产物 + 原厂备份。
> 预计耗时：约 20 分钟（含 rootfs 刷写 + NV 恢复）。
> 当前版本：**v5.0.0**（commit `5a047fc`，2026-08-27 实测验证）。

---

## 一、准备

### 1.1 下载固件产物

从 GitHub Actions 下载 `openstick-alpine.zip`，解压得到以下文件：

```
gpt_both0.bin       分区表（⚠️ 首次必须刷，但会清 modemst NV，后续需恢复）
aboot.mbn           lk2nd 引导（替代原厂 aboot，能引导 mainline 内核）
hyp.mbn             Hypervisor
rpm.mbn             资源电源管理
sbl1.mbn            第一阶段引导
tz.mbn              TrustZone
boot.bin            内核 6.12 + DTB（含 sim-sel gpio114 + LED trigger 等定制）
alpine_rootfs.bin   Alpine rootfs（含开机自动 SIM 激活 + NAT + sp970-link + LED 守护）
```

### 1.2 确认原厂备份

从你的原厂分区全备份中，找到以下两个文件（**关键！没有它们刷完 modem 无法上网**）：

- `modem_st1.mbn`（或 `modemst1.bin` / `backup_p4.bin`）—— modemst1 分区 dump（约 1.5MB）
- `modem_st2.mbn`（或 `modemst2.bin` / `backup_p5.bin`）—— modemst2 分区 dump（约 1.5MB）

> **如何确认是 modemst**：原厂 Android 分区表里，modemst1/modemst2 通常是小分区（1~2MB），名为 modemst1 / modemst2。如果你按分区号 dump 的，对照原厂分区表找到对应分区号。
>
> 如果备份文件名不含 modemst，但你知道哪个分区号是 modemst1/modemst2，直接用对应文件即可。
>
> **没有这两个文件就不能刷！** 刷 GPT 会清空 modemst，导致 modem 无 IMEI、无法上网，且无法恢复（除非有 QCN + QPST 工具走 EDL 模式恢复，非常麻烦）。

### 1.3 准备工具

- **fastboot**：Android Platform Tools（`fastboot.exe`）
- **SSH 客户端**：Windows 自带 `ssh`（或 PuTTY / MobaXterm）
- **文件传输**：用 `scp`（Windows 自带 OpenSSH）

### 1.4 设备进入 fastboot 模式

1. 设备断电（拔 USB）
2. **按住 reset 按钮不放** → 插上 USB → 保持按住约 5 秒 → 松开
3. PC 上执行 `fastboot devices`，应显示设备序列号 + `fastboot`

```
> fastboot devices
7d50d04b  fastboot
```

---

## 二、刷机（fastboot 阶段）

> 以下命令在固件产物所在目录执行。将 `fastboot.exe` 替换为你的实际路径。
> 建议每步确认输出 `OKAY` 后再执行下一步。

### 2.1 刷分区表（首次必须！⚠️ 会清 modemst NV）

```
fastboot flash partition gpt_both0.bin
```

> **重要**：这一步把 Android 28 区分区表替换为 OpenStick 14 区。**刷完后 modemst(NV) 被清空**（IMEI 丢失），必须在步骤四恢复。

### 2.2 刷引导加载器

```
fastboot flash aboot aboot.mbn
fastboot flash hyp hyp.mbn
fastboot flash rpm rpm.mbn
fastboot flash sbl1 sbl1.mbn
fastboot flash tz tz.mbn
```

### 2.3 刷内核 + rootfs

```
fastboot flash boot boot.bin
```

rootfs 较大（约 164MB），加 `-S 256M` 参数加速：

```
fastboot -S 256M flash rootfs alpine_rootfs.bin
```

> 刷写约 1~2 分钟，中途不要断电。

### 2.4 重启

```
fastboot reboot
```

---

## 三、等待启动（首次约 2~4 分钟）

设备重启后：
1. **红灯心跳**出现 = 系统已启动（DTS probe 阶段）
2. **绿灯心跳**出现 = led-daemon 接管，系统就绪
3. **WiFi 热点**出现：SSID `Openstick`，密码 `openstick`
4. PC 连上这个 WiFi 热点

> 此时 modem **无 NV（IMEI unknown）**，4G 还不能上网（正常，下一步恢复）。
> WiFi 热点正常 = 系统启动成功。
>
> **冷启动注意**：sim-activate 完成后，数据面（bearer/wwan0-IP）还要 ~40s 才收敛，冷重启后请等 ~90s 再验证基线。

### LED 状态指示

| 阶段 | 红 (red:os) | 绿 (green:4g) | 蓝 (blue:wifi) |
|---|---|---|---|
| 上电 (DTS probe ~1.5s) | 心跳 | 关 | 关 |
| 系统就绪 (led-daemon ~20s) | 关 | 心跳 | phy0tx（WiFi 数据活动时闪） |

---

## 四、恢复 modemst NV（关键！不做则 4G 不可用）

### 4.1 SSH 连接设备

```
ssh user@192.168.4.1
密码: 1
```

> 如果提示 host key 变化，先执行 `ssh-keygen -R 192.168.4.1`。

### 4.2 上传 modemst 备份到设备

在 PC 上（新开一个终端），把备份文件传到设备：

```
scp modem_st1.mbn user@192.168.4.1:/tmp/mst1.bin
scp modem_st2.mbn user@192.168.4.1:/tmp/mst2.bin
```

> 如果 scp 因 dropbear 无 SFTP 子系统失败，用管道模式：
> ```
> type modem_st1.mbn | ssh user@192.168.4.1 "sudo -n sh -c 'cat > /tmp/mst1.bin'"
> type modem_st2.mbn | ssh user@192.168.4.1 "sudo -n sh -c 'cat > /tmp/mst2.bin'"
> ```

### 4.3 写入 modemst 分区

在 SSH 会话中执行：

```bash
# 确认文件已上传
ls -la /tmp/mst1.bin /tmp/mst2.bin

# 写入 p4(modemst1) 和 p5(modemst2)
sudo dd if=/tmp/mst1.bin of=/dev/mmcblk0p4 bs=4096
sudo dd if=/tmp/mst2.bin of=/dev/mmcblk0p5 bs=4096
sync

# 验证（应该显示真实 IMEI，不是 unknown）
qmicli -d /dev/wwan0qmi0 --dms-get-ids
```

> 输出应显示 `IMEI: '868396066290332'`（你的设备 IMEI），不再是 `unknown`。

### 4.4 重启设备

```bash
sudo reboot
```

SSH 会断开，等设备重启完成（绿灯心跳 + WiFi 热点出现，约 90s）。

---

## 五、验证（刷机完成）

重新连上 WiFi 热点后：

```bash
ssh user@192.168.4.1
```

### 5.1 检查版本

```bash
cat /etc/openstick-version
```

应显示 `v5.0.0 (2026-08-27, commit 5a047fc ...)`

### 5.2 检查开机自动联网日志

```bash
cat /var/log/sim-activate.log
```

应显示完整链路：
```
=== sim-activate start ===
QMI port ready
AID=A0000000871002FF86FF0389FFFFFFFF (自动发现)
provision done, USIM ready on pass 1
CFUN=1 sent
registration wait done (1 iters, reg=1)
mm-start: rc-service modemmanager start
mm-start rc-service: * Starting modemmanager ... [ ok ]
=== sim-activate end (modem via mmcli) ===
```

### 5.3 用 sp970-link 检查链路

```bash
sp970-link card     # 卡状态
sp970-link status   # 链路状态
```

预期输出：
```json
{"state":"present-ready","slot1":"present","usim":"ready"}

{"link_state":"up","card":"present-ready","mm_running":true,"mm_state":"connected",
 "signal":"83","operator":"CHN-CT","nas":"registered","wwan_ip":"10.x.x.x",
 "default_route":"10.x.x.x","ping":"yes","bdmux":"active"}
```

`link_state=up` = 上网正常，刷机完成。

---

## 六、刷机后常用功能（sp970-link）

固件内置 `sp970-link` CLI（位于 `/usr/local/bin/sp970-link`，非登录 shell 需全路径或用 `sudo sp970-link`），提供三个子命令，JSON 输出：

### 6.1 查卡状态

```bash
sp970-link card
```

| 返回 state | 含义 |
|---|---|
| `present-ready` | 有卡，USIM 已激活 |
| `present-detected` | 有卡，USIM 未激活（需 `sp970-link up`） |
| `absent` | 无卡（或卡拔了/插了 modem 没检测到） |

### 6.2 查链路状态

```bash
sp970-link status
```

返回 `link_state` 5 态状态机：

| link_state | 含义 | 典型场景 |
|---|---|---|
| `up` | 上网正常 | 有卡 + MM connected + wwan0 有 IP + ping 通 |
| `card-no-net` | 有卡，网络服务还没拉起 | 刚刷完/重启后 MM 还没起 |
| `no-card` | 无卡 | 卡拔了，或插了 modem 没检测到 |
| `net-down` | 有卡 + MM 在跑但没连上 | MM searching / 无 IP / 未注册 |

### 6.3 拉起网络

```bash
sp970-link up
```

**这个命令做完整恢复**（约 40s）：
1. 停 ModemManager
2. 若卡不在（`absent`）→ `uim-sim-power-off` + `uim-sim-power-on` 让 modem 重新检测卡（**免重启 modem**）
3. 跑 sim-activate 流程（provisioning + CFUN=1 + 注册 + 起 MM）
4. 返回恢复结果

```json
{"ok":true,"link_state":"up","method":"powercycle+sim-activate","duration_s":44}
```

### 6.4 典型使用场景

**场景 1：开机后等一下检查是否联网**
```bash
sp970-link status
# link_state=up → 正常，不用管
# link_state=card-no-net → 还在起，等 30s 再查，或 sp970-link up
```

**场景 2：拔了 SIM 卡再插回，网络没自动恢复**
```bash
sp970-link card
# state=absent → modem 没检测到卡（正常，modem 不主动检测插回）

sp970-link up
# 自动 power-cycle 重见卡 + sim-activate → 联网恢复
```

**场景 3：调试/诊断**
```bash
sp970-link status
# 看 mm_state / nas / wwan_ip / ping / bdmux 各字段定位问题
# bdmux=suspended/active = 正常；bdmux=error = 数据面锁死（需重启设备）
```

---

## 七、热插拔行为（实测结论）

> 以下为 v5 干净基线上的实测结论（2026-08-27，两轮验证复现）。

### 拔卡

- modem **≤2s** 检测到拔卡：SIM 状态 `present` → `possibly-removed`
- ModemManager `connected` → `searching`
- wwan0 **接口保持 UP**，但丢 IP / 丢默认路由
- bearer 对象不立即拆除
- bam-dmux 保持 `suspended`（**不锁死**）

### 插回卡（无干预）

- **modem 不主动检测插回**——SIM 状态全程 `possibly-removed`，180s+ 无任何变化
- **不会自愈**，必须手动恢复

### 恢复

```bash
sp970-link up    # 自动完成 power-cycle + sim-activate，~40s 恢复联网
```

> **原理**：modem 不主动检测物理插回（N958St 固件限制），`sp970-link up` 用 `uim-sim-power-off`+`uim-sim-power-on` 让 modem 重新枚举卡（免重启 modem/remoteproc），再跑 sim-activate 流程。

---

## 八、后续更新（已刷 Alpine，只换固件版本）

如果设备已刷过 Alpine，只需更新 boot + rootfs（**不刷 partition、不刷 bootloader**）：

```
fastboot flash boot boot.bin
fastboot -S 256M flash rootfs alpine_rootfs.bin
fastboot reboot
```

> **不要刷 `gpt_both0.bin`**——会清 modemst NV，需要重新执行步骤四恢复。
>
> 如果改了 DTS，boot.bin 里已含新 DTB，刷 boot 即可。

---

## 九、故障排查

### 9.1 刷完后无 WiFi 热点

| 现象 | 可能原因 | 解决 |
|---|---|---|
| 绿灯心跳亮但无 WiFi | 固件构建有 bug（runlevels 缺服务） | 用 USB NCM `192.168.5.1` SSH 检查 `rc-status default` |
| 无灯、无任何反应 | boot/aboot 刷写失败 或 DTB 损坏 | 重新进 fastboot 刷 boot + aboot；确认 DTB 编译用 dtc（非 cpp） |
| 红灯一直亮不变绿 | led-daemon 未跑 或 sysfs 未就绪 | SSH 检查 `ls /etc/local.d/led-daemon.start` |

### 9.2 WiFi 通但 4G 不工作

| 现象 | 可能原因 | 解决 |
|---|---|---|
| IMEI = unknown | NV 未恢复（忘了步骤四） | 执行步骤四恢复 modemst |
| IMEI 正常但 modem factory-test | NV 恢复但 modem 未重启 | `sudo reboot` 重启设备 |
| sim-activate.log 无记录 | local.d 脚本未固化或 local 服务未启动 | 检查 `ls /etc/local.d/` 和 `rc-service local status` |
| sp970-link status = no-card | SIM 卡拔了或没插好 | 插卡后 `sp970-link up` |
| sp970-link status = net-down | MM searching / 无 IP | `sp970-link up` 恢复 |
| bdmux = error | bam-dmux PM 锁死（手动 UP wwan0 触发） | **只能重启设备**（软件无解） |

### 9.3 SSH 连不上

```
# 清理旧 host key
ssh-keygen -R 192.168.4.1
ssh-keygen -R 192.168.5.1
# 重试
ssh user@192.168.4.1
```

> USB NCM 通道（192.168.5.1）可能因 gadget 错误不通，优先 WiFi。

---

## 附 A：文件清单与分区对应

| 固件文件 | fastboot 分区 | 首次刷 | 更新时 | 说明 |
|---|---|---|---|---|
| `gpt_both0.bin` | partition | ✅ | ❌ | 分区表（清 NV，首次后不再刷） |
| `aboot.mbn` | aboot | ✅ | 可选 | lk2nd 引导 |
| `hyp.mbn` | hyp | ✅ | 可选 | |
| `rpm.mbn` | rpm | ✅ | 可选 | |
| `sbl1.mbn` | sbl1 | ✅ | 可选 | |
| `tz.mbn` | tz | ✅ | 可选 | |
| `boot.bin` | boot | ✅ | ✅ | 内核+DTB |
| `alpine_rootfs.bin` | rootfs | ✅ | ✅ | rootfs（每次更新必刷） |
| `modem_st1.mbn`（备份） | mmcblk0p4 | NV 恢复用 | — | dd 写入，非 fastboot |
| `modem_st2.mbn`（备份） | mmcblk0p5 | NV 恢复用 | — | dd 写入，非 fastboot |

## 附 B：设备连接

| 通道 | 地址 | 说明 |
|---|---|---|
| WiFi 热点 | `192.168.4.1` | SSID `Openstick` / 密码 `openstick`（优先） |
| USB NCM | `192.168.5.1` | 设备 U 口插 PC（备份通道，可能不通） |
| SSH | `user / 1` | 两通道都走 22 |

## 附 C：固件内容（v5.0.0）

| 组件 | 位置 | 说明 |
|---|---|---|
| sim-activate.start | /etc/local.d/ | 开机自动 SIM 激活 + 联网（方案 B） |
| nat.start | /etc/local.d/ | WiFi→4G NAT 转发 |
| led-daemon.start | /etc/local.d/ | LED 状态指示（红→绿心跳） |
| sp970-link | /usr/local/bin/ | 链路接口 CLI（card/status/up） |
| ModemManager | 不开机自启 | sim-activate 起一次，D-Bus 激活已禁 |
| 版本标识 | /etc/openstick-version | 含完整 git hash |
