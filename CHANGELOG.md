# SP970 OpenStick 固件变更日志

版本号来源：仓库根 `VERSION` 文件。每次功能变更递增，构建时写入固件 `/etc/openstick-version` + `/etc/openstick-changelog.md`。

## [5.0.0] - 2026-08-27（待构建）

### 新增
- **`sp970-link` 链路接口（设备端 CLI）**：`/usr/local/bin/sp970-link`（+ `/usr/bin` 符号链接进非登录 PATH）。三个子命令，JSON 输出：
  - `sp970-link card`：卡状态（`present-ready`/`present-detected`/`absent`）
  - `sp970-link status`：链路状态机 5 态（`up`/`card-no-net`/`no-card`/`net-down`）+ 全字段（card/mm_running/mm_state/nas/wwan_ip/route/ping/bdmux）
  - `sp970-link up`：拉起——停 MM →（卡不在则 `uim-sim-power-off`+`on` 重见卡，免 remoteproc 重启）→ `sim-activate.start` → 返回 `{ok,link_state,method,duration_s}`
  - 稳定解析：`mmcli -K`（key=value 无 ANSI）+ `ip -o` + qmicli 去 ANSI + 锚定正则；规避坑#2/#3/#2.5。
- **热插拔研究结论（固化）**：拔卡→`searching`/`possibly-removed`/wwan0 保留(丢IP)/bearer 未拆/bam-dmux 不锁；插回→modem **不主动检测**（sim 全程 `possibly-removed`，不自愈）；最小热恢复=`uim-sim-power-off`+`on` 重见卡 + sim-activate 流程，~40-44s，**免 remoteproc 重启**（推翻 v4 时期"必须 remoteproc 重启"的旧结论）。

### 变更
- **DTS sim-sel 修正**：`sim_select`(gpio26, ACTIVE_LOW) → `sim-sel`(gpio114, ACTIVE_HIGH, off→boot 驱动 LOW)。gpio114 LOW=**物理 SIM**（与 q410 `msm8916-gexing-sp970.dts` 验证过的配置逐字一致；`切卡研究资料.txt` V13 的"0=eSIM"不适用本板）。modem/bam-dmux/wwan 拓扑不变（SoC 级，overlay 未碰），`sp970-link`/`sim-activate` 硬编码路径不受影响。
- `sp970-link` 不开机自启（按需调用）；boot 仍走 `sim-activate.start`（已验证开箱即用）。boot 可选末尾追加 `sp970-link status` 日志（v5 暂未加）。

## [4.0.0] - 2026-08-26（待构建）

### 新增
- **SIM 开机自动激活（方案 B，通用）**：`sim-activate.start` 开机**自动发现 USIM AID（读卡）+ provisioning 激活 + CFUN=1 + 起 MM**。支持任意运营商 SIM（不硬编码电信 AID）。
- **ModemManager 开机不自启 + 禁 D-Bus 激活**：MM 在 boot 阶段不碰 modem（否则 N958St `Get Slot Status NotSupported` 会让 MM 误判 sim-missing 并 power-off modem）。激活完成后再启动 MM，MM+NM 自动建承载/配 IP/DNS。
- **WiFi→4G NAT 固化**：`nat.start` 开机 iptables MASQUERADE + ip_forward（随身 WiFi 形态）。
- **固件版本标识**：`/etc/openstick-version`（`v4.0.0 + 完整 git hash + 日期`），`/etc/openstick-changelog.md`
- **rootfs 收缩**：`resize2fs -M`，刷机产物 1.5GB→~163MB，刷写大幅加速
- **首次启动扩容**：`expand-rootfs.start` 自动扩展 rootfs 用满分区

### 变更
- 固件来源：`analysis/OpenStick-Builder-fork/` 的 `sp970-future` 分支
- 依赖：modemmanager + qmi-utils + msm-firmware-loader，modem/WCNSS 固件内置 rootfs
- **刷机 SOP**：禁刷 `partition(GPT)`——实测会清空 modemst(NV)（IMEI 丢失→factory-test 无法上网）。刷 boot/rootfs 即可保留 NV。
- **rootfs 构建分模式**：debug（默认，`resize2fs -M` 收缩 ~200MB 快刷）/ release（workflow 勾选 release 或 `FULL_ROOTFS=1`，满分区 ~3.47GB）。**删除开机扩容脚本**（挂载中的 rootfs 无法 resize2fs，原 expand-rootfs 是无效 no-op）。

### 修复
- modem 固件缺失导致 remoteproc 加载失败（上传后正常）
- QMI 端口就绪前 MM 启动导致 "No modems found"
- **SIM 无法自动激活**：旧方案（MM 自启 + 硬编码 AID + 停/起 MM）改为方案 B（MM 不自启 + 自动 AID/APN），省掉"停 MM / 重启 modem / 手动配 IP"三步，开机 ~1 分钟自动联网（已实测）。

## [3.0.0] - 2026-08-24（sp970-future-v3，已刷入设备）

### 新增
- **SP970 定制 DTB**：gpio26 sim_select 节点（低电平=物理 SIM）
- **modem 固件入 rootfs**：mba.mbn + modem.b*（firmware/modem/sp970/）
- **WCNSS 固件 + NV 校准入 rootfs**（firmware/sp970/）
- WCNSS smem-state 绑定修复（6.12+ 内核）

### 状态
- SIM 硬件识别正常（gpio26 生效），但**无 qmi-utils/开机激活**（qmicli 需手动）
- modem 数据连接不稳定：MM 激活后不自动配 IP，需手动 netfix

## [2.0.0] - 2026-08-23（sp970-future-v2，旧版）

### 变更
- 首个可刷机的 SP970 Alpine 镜像
- WiFi 开箱即用（Openstick/openstick），USB NCM 网络

### 已知问题
- 无 gpio26 配置，SIM 无法识别
- 无 modem 固件，modem 完全不可用
