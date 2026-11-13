# iStoreOS for 京东云亚瑟 AX1800 Pro（RE-SS-01）

基于 [iStoreOS](https://github.com/istoreos) `25.12` 分支，适配 **京东云亚瑟 AX1800 Pro（内部型号 RE-SS-01，IPQ6000，eMMC）** 的独立构建仓库，通过 GitHub Actions 自动编译固件。

## 支持设备

| 项目 | 说明 |
| --- | --- |
| 设备名 | 京东云亚瑟 AX1800 Pro |
| 内部型号 | JDCloud RE-SS-01 |
| SoC | Qualcomm IPQ6000（四核 Cortex-A53） |
| 内存 | 512 MB / 1024MB |
| 存储 | eMMC（无 NAND） |
| OpenWrt 标识 | `jdcloud_re-ss-01` |
| 目标子架构 | `qualcommax / ipq60xx` |

## 内置软件

- **eBPF / BTF 内核支持**：已开启 BTF、XDP、BPF Events、CGROUPS、BPF 工具链，并内置 daed 所需内核模块（kmod-sched-core / kmod-sched-bpf / kmod-veth / kmod-xdp-sockets-diag）；
- **TUN/TAP 虚拟网卡（kmod-tun）**：TUN 模式代理可直接使用。

## 刷机流程

1. 刷 **12M 大分区 U-Boot**（HLOS 12MiB），旧 U-Boot 刷入地址：http://192.168.1.1/uboot.html；
2. 刷 **2GB GPT 模板**（rootfs 扩到 2048MiB，用于装固件，不能省略）；
3. U-Boot 页面刷本项目 `factory.bin`；
4. Web 升级 `sysupgrade.bin`。

### 刷机文件下载

| 文件 | 下载 |
| --- | --- |
| 12M 大分区 U-Boot（jdcloud_re-ss-01） | [直接下载 .bin](https://github.com/chenxin527/uboot-qsdk12.5-build/releases/download/26.08.16-14.22.36-3011049/uboot-ipq60xx-jdcloud_re-ss-01-260816_142236_3011049.bin) |
| GPT 模板（rootfs2048M / HLOS12M） | [直接下载 .bin](https://github.com/natserver/istoreos/raw/refs/heads/sync/istoreos-25.12-20260910/docs/gpt-JDC_AX1800_Pro_dual-boot_rootfs2048M_HLOS12M_no-last-partition.bin) |

### U-Boot 版本说明

<!-- UBOOT-NOTES-START -->
**当前版本**：`26.08.16-14.22.36-3011049` ｜ **发布日期**：2026-08-16 ｜ [作者发布页](https://github.com/chenxin527/uboot-qsdk12.5-build/releases/tag/26.08.16-14.22.36-3011049)

**更新内容**

- **新特性**
  - U-Boot 启动时打印设备信息（设备型号和 config_name）。
  - 支持刷写纯 NOR 固件（分区表参考高通 [meta-tools](https://github.com/chenxin527/meta-tools) 中的 nor-partition.xml），暂不支持刷写单 firmware 分区的纯 NOR 固件。
- **BUG 修复**
  - 修复网络命令 (ping, tftpboot, tftpput 等) 在网页终端/Telnet 终端下执行后 httpd 可能失联的问题。
  - 修复网页终端下部分命令执行时间过长导致 TCP 连接超时的问题。
  - 修复 JDCloud BE6500 的 factory 固件解析失败的问题（将 factory 固件 kernel 大小限制调整为 1 MiB 的整数倍）。
  - 修复 CMIOT AX18、Qihoo 360V6、Redmi AX5 JDCloud 和 ZN M2 部分网口不通的问题。
- **优化**
  - 只在 BOOTCONFIG 分区数据有效时执行 bootconfig 命令，避免用户主动擦除了 BOOTCONFIG 分区的情况下执行该命令导致固件刷写结果返回失败。
  - 优化 9008 模式下的 MIBIB 自动重载逻辑。
  - 优化 tftp/wget 文件传输进度、传输速率及文件大小信息显示。
  - IPQ53xx/IPQ95xx: 防止长时间无网络活动导致 PPE 硬件休眠。
  - wget/flashread: 当用户未指定加载地址且 loadaddr 环境变量未设置时，根据设备内存大小自动设置默认加载地址。
  - autoboot: 若 bootcmd 不是 bootipq 且其运行失败，则自动尝试运行 bootipq。
- **其他**
  - 默认开启 httpd_debug 模式，打印详细的日志信息，便于调试。
  - 调整 CMIOT AX18、Redmi AX5 JDCloud 和 ZN M2 的 LED 配置。
  - 精简部分机型包含的额外 DTB，减小 U-Boot 大小。
<!-- UBOOT-NOTES-END -->

## 安装加强版 daed（大鹅）

国内网络复制链接一键安装：

```sh
wget --no-check-certificate -O - https://ghfast.top/https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh | ash
```

512m内存的设备节点不要搞太多，搞太多爆内存，路由器会死掉。

## 其他翻墙插件

下载地址：[Are-u-ok iStoreOS_25.12 发布页](https://github.com/bcseputetto/Are-u-ok/releases/tag/iStoreOS_25.12)（AX1800 Pro 为 aarch64_a53 架构，请下载对应版本）。

## 无线（手动开启）

## 感谢

iStoreOS：[仓库链接](https://github.com/istoreos/)

## 免责声明

刷机有风险，请自行评估；本仓库仅用于学习交流。

## 许可证

基于 iStoreOS / OpenWrt，遵循 **GPL-2.0**。
