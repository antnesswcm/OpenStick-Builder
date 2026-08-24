# SP970 OpenStick 固件变更日志

版本号来源：仓库根 `VERSION` 文件。每次功能变更递增，构建时写入固件 `/etc/openstick-version` + `/etc/openstick-changelog.md`。

## [4.0.0] - 2026-08-25（待构建）

### 新增
- **SIM 自动激活**：qmi-utils 开机 provisioning USIM（电信卡 AID `A000000087...`），SIM 插入即注册
- **ModemManager 稳定化**：`mm-init.start` 开机等待 QMI 端口就绪后重启 MM
- **固件版本标识**：`/etc/openstick-version`（`v4.0.0 + 完整 git hash + 日期`），`/etc/openstick-changelog.md`
- **rootfs 收缩**：`resize2fs -M`，刷机产物 1.5GB→~163MB，刷写大幅加速
- **首次启动扩容**：`expand-rootfs.start` 自动扩展 rootfs 用满分区

### 变更
- 固件来源：`analysis/OpenStick-Builder-fork/` 的 `sp970-future` 分支
- 依赖：modemmanager + qmi-utils + msm-firmware-loader，modem/WCNSS 固件内置 rootfs

### 修复
- modem 固件缺失导致 remoteproc 加载失败（上传后正常）
- QMI 端口就绪前 MM 启动导致 "No modems found"

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
