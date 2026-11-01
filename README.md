# padavan-4.4（mzkingk-ai fork）

基于 [vb1980/padavan-4.4](https://github.com/vb1980/padavan-4.4) 的 MT7621 固件树，内核 4.4.198。

本 fork 面向 **128MB 内存的 NEWIFI3(D2)**：默认配置下 xray 双进程 + dnsmasq 大缓存太吃内存，
项目自带的 BBR 补丁在 MIPS 上跑几小时就崩。所以改动集中在**降内存、修静默失败、把网易云
音乐解锁做成固件内置功能**三件事上。

> 主力验证机型 **NEWIFI3（D2）**，运行 `4.4.198.9`。其余机型沿用上游模板，未充分验证。

---

## 本 fork 的适配点

相对上游 364 个提交中，有 **44 个是本仓库的改动**。

### 内存优化（约省 25MB）

| 改动 | 位置 | 收益 |
|---|---|---|
| xray TCP+UDP 合并单进程 | `trunk/user/shadowsocks/ss/genxrayconfig.lua` | ~16 MB |
| `GOGC=30`（默认 100） | `trunk/user/shadowsocks/scripts/shadowsocks.sh` | ~5~8 MB |
| 单连接 pipe 缓冲上限 20MB（MIPS 默认无限制） | 同上 | 防无界增长 |
| DNS 缓存 1024 → 512、`net.core` 收发缓冲 960KB → 320KB、日志轮转 512KB → 256KB | `trunk/user/rc/rc.h` | ~3.5 MB |
| `vm.overcommit_memory=1` | `trunk/user/rc/init.c` | Go runtime 必需 |
| 预编译精简版 xray（4.5MB → 3.76MB） | `trunk/user/xraymin/xray` | flash |

### xray / shadowsocks 链路修复

- **配置格式**：`inbound`/`outbound`（单数）改为 `inbounds`/`outbounds`（数组）。旧写法
  `xray -test` 能过，但 xray 忽略未知键，**根本没监听端口**。
- **39 秒重启循环**：`shadowsocks.sh` 与 `ssr-monitor` 的参数位错位，用 xray 时 monitor
  误查 `ssr-local`，找不到就重启。
- **35 秒重启循环**：TCP+UDP 合并后仍置 `redir_udp=1`，monitor 找不到 `ssr-reudp` 就重启。
- **服务器地址自动写 `/etc/hosts`**，避免代理 DNS 回环。

### 网易云音乐解锁（WYYBIN）

固件内置 `UnblockNeteaseMusic`（Go 版），WebUI「高级设置 → 网易云音乐」内开关、配置、证书管理。

- 包本体：`trunk/user/unblockneteasemusic/`（Makefile + 守护脚本 + [插件 README](trunk/user/unblockneteasemusic/README.md)）
- 页面：`trunk/user/www/n56u_ribbon_fixed/Advanced_wyybin.asp`
- 开关：`CONFIG_FIRMWARE_INCLUDE_WYYBIN`（NEWIFI3 默认 `y`，其他机型 `n`）
- 支持纯代理（默认）与 dnsmasq 劫持两种模式；证书目录可配，切换时自动补拷；出厂证书随固件走
- 插件自身的代码改动在独立 fork [mzkingk-ai/UnblockNeteaseMusic](https://github.com/mzkingk-ai/UnblockNeteaseMusic) 维护

### 构建体系

- `toolchain-mipsel/`、源包 tarball 移出版本库，编译时按需下载
- `UnblockNeteaseMusic` 改为 `git clone --depth=1` 拉 fork 最新源码（`UNM_REF` 可钉版本）
- xray/v2ray 在 `build` 末尾就地 UPX 压缩；内置静态 `trunk/tools/bin/upx`
- **Go 版本闸门**：go1.23+ 的 runtime 在 MT7621 上 `futexwakeup` 返回 `-89` 后 `SIGSEGV`，
  Makefile 直接报错拦住，不静默产出装上去就死的固件
- 三处容器构建补丁（samba36 uuid 头守卫、ntfs-3g autoconf 宏兜底、UPX 工具）纳入版本库

### 其它

- **SmartDNS** 升级到 `Release48.4`，修正集成脚本与缓存输入框
- **NTFS 挂载**优先 `antfs` 内核驱动、`ntfs-3g` 回退；修 ntfs-3g 交叉编译需 `autoreconf`
- **R2100/RM2100**：型号切换与配置移到 `build-padavan.sh`，RM2100 换 OpenSSH
- **BBR 已完整回退**（MIPS 上跑几小时会崩），当前用内核默认拥塞控制

---

## 编译

```sh
# 起容器（工具链是 x86-64 预编译包）
docker run -d --name padavan-build -v "$PWD":/opt -w /opt ubuntu:22.04 sleep infinity

# 装依赖（一次性）
docker exec padavan-build bash -c '
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential automake autoconf libtool-bin gperf gawk flex bison \
    libncurses5-dev libltdl-dev texinfo help2man python3-docutils gettext \
    autopoint pkg-config zlib1g-dev libgmp3-dev libmpc-dev libmpfr-dev \
    wget curl ccache unzip kmod fakeroot cpio git xxd
'

# 编译（首次自动下载工具链，约 90MB）
docker exec padavan-build bash -c 'make NEWIFI3'
```

宿主机直接编译也可以，依赖同上（见上游说明）。Go 程序需 **Go 1.22**。

产物在 `trunk/images/`，D2 上约 **12.3 MB**。切换机型前先 `make clean`。

---

## 刷机

```sh
# 备份
ssh admin@<路由器IP> 'cat /dev/mtd3 > /tmp/firmware.bak'
scp admin@<路由器IP>:/tmp/firmware.bak .

# 写入（必须写 firmware 整体分区）
scp NEWIFI3_*.trx admin@<路由器IP>:/tmp/fw.trx
ssh admin@<路由器IP> 'mtd_write write /tmp/fw.trx firmware'
ssh admin@<路由器IP> 'reboot'
```

D2 建议先刷 breed，刷坏了可以退回。

---

## 已知限制

- **Go 必须 1.22**，不要绕过 Makefile 的版本闸门
- **BBR 不可用**
- **仅 NEWIFI3 充分验证**
- 网易云解锁依赖第三方音源接口，失效时需更新 UNM fork 后重编
- 历史被重写过（清除大文件），其他克隆需重新 clone

---

## 许可

继承上游 GPL-2.0。`UnblockNeteaseMusic` 上游为 MIT，派生改动同样按 MIT 分发。
