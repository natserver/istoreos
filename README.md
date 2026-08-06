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

## 内置软件

- **eBPF / BTF 内核支持**：已开启 BTF、XDP、BPF Events、CGROUPS、BPF 工具链，并内置 daed 所需内核模块（kmod-sched-core / kmod-sched-bpf / kmod-veth / kmod-xdp-sockets-diag）；

## 无线（手动开启）

## 刷机流程

1. 刷 **12M 大分区 U-Boot**（HLOS 12MiB）；
2. 刷 **2GB GPT 模板**（rootfs 扩到 2048MiB，用于装固件，不能省略）；
3. U-Boot 页面刷本项目 `factory.bin`
4. Web 升级 `sysupgrade.bin`。

### 刷机文件下载

| 文件 | 下载 |
| --- | --- |
| 12M 大分区 U-Boot（jdcloud_re-ss-01） | [直接下载 .bin](https://github.com/chenxin527/uboot-qsdk12.5-build/releases/download/26.07.30-18.39.45-e7ba635/uboot-ipq60xx-jdcloud_re-ss-01-260730_183945_e7ba635.bin) · [Releases 页](https://github.com/chenxin527/uboot-qsdk12.5-build/releases) |
| GPT 模板（rootfs2048M / HLOS12M） | [直接下载 .bin](https://github.com/GHNERCH/DAEWRT-AX1800PRO/raw/main/gpt-JDC_AX1800_Pro_dual-boot_rootfs2048M_HLOS12M_no-last-partition.bin) · [仓库页](https://github.com/GHNERCH/DAEWRT-AX1800PRO) |

## 免责声明

刷机有风险，请自行评估；本仓库仅用于学习交流。

## 许可证

基于 iStoreOS / OpenWrt，遵循 **GPL-2.0**。
