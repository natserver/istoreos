# iStoreOS for 京东云亚瑟 AX1800 Pro（RE-SS-01）

基于 [iStoreOS](https://github.com/istoreos) `25.12` 分支，适配 **京东云亚瑟 AX1800 Pro（内部型号 RE-SS-01，IPQ6000，eMMC）** 的独立构建仓库，通过 GitHub Actions 自动编译固件。

## 支持设备

| 项目 | 说明 |
| --- | --- |
| 设备名 | 京东云亚瑟 AX1800 Pro |
| 内部型号 | JDCloud RE-SS-01 |
| SoC | Qualcomm IPQ6000（四核 Cortex-A53） |
| 内存 | 512 MB |
| 存储 | eMMC（无 NAND） |
| OpenWrt 标识 | `jdcloud_re-ss-01` |
| 目标子架构 | `qualcommax / ipq60xx` |

## 自动构建

推送到 `istoreos-25.12` 分支时自动编译，产物（Artifact 名 `istoreos-jdcloud-re-ss-01`）包含：

- `istoreos-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin`
- `istoreos-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin`
- 对应 `.manifest`

内核按双启动 GPT 编译为 **12 MiB（`KERNEL_SIZE=12288k`）**，需配合下方分区表与 U-Boot 端点使用。

## 刷机方法

1. **准备**：双启动分区表镜像（如 `gpt-JDC_AX1800_Pro_dual-boot_rootfs2048M_HLOS12M_no-last-partition.bin`，HLOS 分区 12M）；进入 U-Boot Web 恢复模式（断电按住复位键上电，LAN 口设静态 IP `192.168.1.x`）。
2. **写分区表**：U-Boot Web 先上传并写入 GPT 镜像。
3. **刷 factory.bin**：在 U-Boot Web 通过 **`/big.html`** 端点（12M 内核专用）上传写入，完成后断电重启。
4. **升级**：进入系统后用 `sysupgrade.bin` 升级。

> ⚠️ 本机型用 12M HLOS 分区，必须走 `/big.html` 端点；`/` 端点对应 6M 内核，与本网 GPT 不匹配，误用会导致红灯不启动。

## 免责声明

刷机有风险，操作前请备份原厂固件与分区表。本仓库仅供学习研究，作者不对任何刷机导致的设备损坏负责。

## 许可证

基于 iStoreOS / OpenWrt，遵循 **GPL-2.0**。
