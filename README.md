# iStoreOS for 京东云亚瑟 AX1800 Pro（RE-SS-01）

基于 [iStoreOS](https://github.com/istoreos) `25.12` 分支，针对 **京东云亚瑟 AX1800 Pro（内部型号 RE-SS-01，Qualcomm IPQ6000，eMMC 存储）** 适配的独立构建仓库。

本仓库通过 GitHub Actions 自动编译该机型的 iStoreOS 固件，产物为 `factory.bin`（首次刷入）与 `sysupgrade.bin`（升级）。

## 支持设备

| 项目 | 说明 |
| --- | --- |
| 设备名 | 京东云亚瑟 AX1800 Pro |
| 内部型号 | JDCloud RE-SS-01 |
| SoC | Qualcomm IPQ6000（四核 ARM Cortex-A53） |
| 内存 | 512 MB |
| 存储 | eMMC（本板无 NAND） |
| 无线 | 2.4G + 5G（QCA 方案） |
| OpenWrt 设备标识 | `jdcloud_re-ss-01` |
| 目标子架构 | `qualcommax / ipq60xx` |

## 自动构建（GitHub Actions）

根目录的 `.github/workflows/build-ax1800pro.yml` 会在推送到 `istoreos-25.12` 分支时自动编译，产物以 **Artifact** 形式上传（名称 `istoreos-jdcloud-re-ss-01`），包含：

- `istoreos-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin`
- `istoreos-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin`
- 对应的 `.manifest`

> 内核已按本机型的双启动 GPT 编译为 **12 MiB（`KERNEL_SIZE=12288k`）**，需配合下方分区表与 U-Boot 恢复端点使用。

## 刷机方法

### 0. 准备

- 一张双启动分区表镜像（社区常用 `gpt-JDC_AX1800_Pro_dual-boot_rootfs2048M_HLOS12M_no-last-partition.bin`，其 HLOS 分区为 12M）。
- 进入 U-Boot Web 恢复模式（通常断电状态下按住复位键上电，待指示灯变化后松开；电脑网线接 LAN 口，设置静态 IP `192.168.1.x`）。

### 1. 写入分区表

在 U-Boot Web 界面先上传并写入上面的 GPT 镜像，使 eMMC 具备 12M 的 HLOS 分区。

### 2. 刷入 factory.bin

继续在 U-Boot Web 中通过 **`/big.html`** 端点（12M 内核专用）上传 `factory.bin` 写入。写入完成后断电重启。

> ⚠️ 本机型因使用 12M HLOS 分区，必须使用 `/big.html` 端点；`/` 端点适用于 6M 内核，与本 GPT 不匹配，强行使用会导致无法启动（红灯）。

### 3. 后续升级

已进入系统后，升级使用 `sysupgrade.bin`（Web 界面或 `sysupgrade` 命令）。

## 关键适配点（排查记录）

- **eMMC 控制器**：RE-SS-01 的 eMMC 接在 SDC1，设备树中对应 `&sdhc_1`；若误配在 `&sdhc`（SDC2 / SD 卡槽），内核会找不到 eMMC，卡在 `Waiting for root device` 后看门狗复位（红灯）。已修正为 `&sdhc_1` 并禁用 `&sdhc`。
- **12M 内核**：因刷入的是 `HLOS12M` GPT，内核须 pad 到 12M 并走 `/big.html` 端点，否则 rootfs 偏移落在 HLOS 分区边界外。
- **cmdline**：`/chosen` 显式设置 `bootargs`，保证控制台与根设备正确挂载。

## 本地编译（可选）

需要大小写敏感的文件系统（Linux / macOS / WSL）。

```bash
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig        # Target: Qualcommax/IPQ60xx，勾选 jdcloud_re-ss-01
make -j$(nproc)
```

编译产物位于 `bin/targets/qualcommax/ipq60xx/`。

## 分支说明

- `istoreos-25.12`：默认分支，本机型的适配与构建分支。

## 免责声明

刷机有风险，操作前请备份原厂固件与分区表。本仓库仅供学习研究，作者不对任何刷机导致的设备损坏负责。

## 许可证

基于 iStoreOS / OpenWrt，遵循 **GPL-2.0**。
