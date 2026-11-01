# UnblockNeteaseMusic（Padavan 插件，Go 版）

把 [cnsilvan/UnblockNeteaseMusic](https://github.com/cnsilvan/UnblockNeteaseMusic)（MIT）
集成进 Padavan 4.4 的 MT7621 固件，在「高级设置 → 网易云音乐」页面里开关。

## 上游与取源

| 项目 | 值 |
|---|---|
| 上游仓库 | `cnsilvan/UnblockNeteaseMusic` |
| 固定 commit | `91afd9361e8bb5308c3a6f8bba39a577eaba76be`（2024-07-31） |
| 版本号 | `0.2.13`（上游 release 只到 2021-11-04 的 0.2.13，之后只有 master 源码） |
| 取源方式 | `https://github.com/cnsilvan/UnblockNeteaseMusic/archive/<commit>.tar.gz` |
| 依赖 | 仅 `mapstructure v1.4.2` + `golang.org/x/text v0.3.3`，`go.mod` 声明 go 1.16 |

上游 JS 版（`UnblockNeteaseMusic/server`）需要 Node.js，而 Padavan 树里没有任何 node 包，
体积也不适合 128MB 设备，因此选 Go 版。

## 目录结构

```
trunk/user/unblockneteasemusic/
├── Makefile                      构建规则（解包 → 打补丁 → 交叉编译 → romfs）
├── patches/
│   ├── 0001-router-and-unlock-fixes.patch   路由与解锁链路修复
│   └── 0002-multi-source-fixes.patch        多音源稳定性（并发/代理/超时）
├── unblockneteasemusic.sh        运行时控制脚本（start/stop/restart/status/watch/cert/regen）
├── UnblockNeteaseMusic-<commit>.tar.gz      上游源码包（git 忽略，缺失时自动下载）
├── UnblockNeteaseMusic-<commit>/            解包目录 = 上游 + 上述两个补丁（git 忽略）
└── bin/UnblockNeteaseMusic                  编译产物（git 忽略，不进版本库）
```

**源码目录永远是「干净解包 + 打两个补丁」。** 要改代码请改补丁，不要直接改解包目录，
否则 `make clean` 一次就全丢了。

## 编译

```sh
cd trunk/user/unblockneteasemusic
make            # 解包 → 打补丁 → 交叉编译，产物在 bin/
```

### 两条硬约束（真机试出来的，别改回去）

**1）编译器必须是 go1.22。**

go1.23+ 的 runtime 用 `lock_spinbit` 自旋锁，在 MT7621 + uClibc 上会让 futex 返回 `-89`
（`ENOSYS`），产物一启动就崩：

```
futexwakeup addr=0x857378 returned -89
SIGSEGV: segmentation violation
PC=0x77c00 m=0 sigcode=128 addr=0x0
```

`Makefile` 里已加版本闸门，用 go1.23+ 会直接报错退出，不会静默产出装上去就死的固件。
`padavan-build` 容器内是 go1.22.12，正好可用。

**2）必须 UPX 压缩（已实测翻案）。**

`upx -9 --lzma` 把 7.34MB 压到 **1.76MB（23.97%）**，固件从 12.32MB 降到 **10.95MB**。

早先这里记着「mipsel 解压器会让 futex 报 `-89`，压缩版一样 SIGSEGV」。2026-11-01 在
NEWIFI3(D2) / 4.4.198 上实测推翻了该结论：

| 检查 | 结果 |
|---|---|
| `/tmp/unm_upx -v` | `Version: 0.2.13` + `go1.22.12 linux/mipsle`，**rc=0** |
| 端口监听 | `:::18080 LISTEN` 正常 |
| 明文代理真实请求 | **`HTTP/1.1 200 OK`**，返回真实 JSON |
| 进程状态 | `S`（正常待命） |

当时踩坑的是宿主机 **go1.26** 编出来的 8.7MB 产物（Go 1.23+ 的 `lock_spinbit` 问题），
不是 UPX 本身。所以约束只有一条：**必须压 go1.22 的产物**。

UPX 步骤已写进 `Makefile` 的 `build` 目标，因为本包每次构建都会重跑 `go build` 覆盖
`bin/UnblockNeteaseMusic`，手工压过的版本会被冲掉。

**字节序**：MT7621 是 MIPS32r2 **小端**（工具链 `mipsel-*`）。`GOARCH=mips` 产出的是大端，
上机 `exec format error`，必须 `GOARCH=mipsle` + `GOMIPS=softfloat`。

## 固件开关

单个开关串起全链路：

| 位置 | 作用 |
|---|---|
| `trunk/configs/templates/NEWIFI3.config:294` | `CONFIG_FIRMWARE_INCLUDE_WYYBIN=y`（其他机型为 `n`） |
| `trunk/user/Makefile:193` | `dir_$(CONFIG_FIRMWARE_INCLUDE_WYYBIN) += unblockneteasemusic` |
| `trunk/user/shared/cflags.mk:215` | `-DAPP_WYYBIN`，让 rc/httpd 编译到对应分支 |
| `trunk/user/www/Makefile:221` | 非 `y` 时删掉 `Advanced_wyybin.asp` |

关掉后：包不编译、页面不打包、菜单项不出现、rc 里也没有相关代码。

## 运行期控制

nvram 变量：默认值写在 `trunk/user/shared/defaults.c` 的 `APP_WYYBIN` 段，
变量声明与 EVM 位在 `trunk/user/httpd/variables.c` 的 `variables_WYYBIN[]`
（`struct variable` 的第二列是 longname，**不是**默认值）。

| 变量 | 默认 | 说明 |
|---|---|---|
| `wyybin_enable` | `0` | `1` 启动，其他值停止 |
| `wyybin_port` | 空→`5200` | HTTP 端口 |
| `wyybin_sslport` | 空→`5201` | HTTPS 端口 |
| `wyybin_source` | 空→`pyncmd:kuwo` | 音源，冒号分隔，如 `pyncmd:kuwo:kugou`；页面下拉只给常见组合 |
| `wyybin_mode` | `0` | `1`=转发模式（写 dnsmasq `address=` 劫持），`0`=纯代理 |
| `wyybin_minscore` | 空→`0.75` | 匹配分数下限，低于此分直接放弃（宁可无结果也不放翻唱） |
| `wyybin_extra` | 空 | 追加到命令行的其他参数；`-bu/-ba/-lv/-sef/-wl` 会被过滤掉（见下） |
| `wyybin_cert` | 空→`/etc/storage/unblockneteasemusic` | 证书目录，相对路径按默认目录解析；带 `EVM_BLOCK_UNSAFE`，只有登录用户能查/改 |
| `wyybin_bu` | `1` | `-bu` 屏蔽升级提示 |
| `wyybin_ba` | `1` | `-ba` 去广告 |
| `wyybin_lv` | `1` | `-lv` 本地伪 VIP |
| `wyybin_sef` | `1` | `-sef` 解锁音效 |
| `wyybin_wl` | `0` | `-wl` 打印请求/响应全文（写 /tmp 内存盘，仅排障时开） |
| `wyybin_qq_enable` | `0` | `1` 时才把 `qq` 留在音源列表（取址需要绿钻账号） |

功能开关是 Go 的 `flag.Bool`（无值开关），语义只有「传=开 / 不传=关」，
所以**不存在**在「额外参数」里显式关掉某一项的写法；脚本会把 `-bu/-ba/-lv/-sef/-wl`
从额外参数里剔除，避免与开关重复或写出 `-wl=1` 这类非法值。

启停链路：

- 开机：`trunk/user/scripts/autostart.sh` 中**先**启动 wyybin、**后**启动 SmartDNS
  （SmartDNS 只在启动时读一遍 `dnsmasq.conf`，顺序反了当轮劫持规则不生效）
- 页面保存：httpd 的 EVM 位 `EVM_RESTART_WYYBIN`（bit 54）→ 写 `restart_wyy` 通知 →
  `trunk/user/rc/rc.c` 分发 → `restart_wyybin()`
- `trunk/user/rc/services.c:569` 的 `wyybin_apply_dns()` 在启停后 `restart_dns()`，
  让转发模式下写入的 dnsmasq 劫持规则生效/撤销
- 证书查询/重签走 `update.cgi?output=wyybin_cert` → `wyybin_cert_hook()`
  → `unblockneteasemusic.sh cert|regen`，返回 `OK|/END=/SUBJ=/FILES=` 或 `ERR|`

## 补丁 0002 改了什么（多源与稳定性，2026-11-01）

切到多音源（`pyncmd:kuwo:kugou:migu`）后暴露的一批问题，逐条如下。

### ① 并发写 map 直接崩进程（最严重）

`provider/provider.go` 的 `buildSearchSong` 里原有一行：

```go
key["musicQuality"] = music.Quality
```

这个值**从来没被读过**（下面的 `Quality` 字段直接用 `music.Quality`），但它让
`resolveSong` 里每个音源的 goroutine 并发写同一个 map。Go 对并发写 map 是
`fatal error`，**`recover` 抓不住**，进程当场退出。单音源时只有一个 goroutine 写，
所以这个问题一直没暴露；改成多源后每次播放必崩。已删除该行。

> 守护 cron 因此保留，但原因不再是这个 bug（见 `unblockneteasemusic.sh` 的 `watch` 分支）。

### ② pyncmd 与换源改为并发竞速

原逻辑是**串行**：先跑 pyncmd，没结果再进换源的 6 秒窗口。pyncmd 内部是最多
3 次 × 8 秒重试，实测能把一次播放请求拖到 25 秒以上，而换源那边几百毫秒就
已经有结果了。现在两边同时发出：

- pyncmd 有结果就用它（它给的是网易原曲，不用猜原唱）；
- 否则取换源里 `MatchScore` 最高、同分取体积大的那条；
- 换源全部返回且已有可用结果 → 立即返回，不再陪慢的 pyncmd 等。

**超时定时器必须建在循环外**：写成 `select { case <-time.After(...) }` 时每轮
循环都会重新计时，收到一条结果就把 deadline 往后推，实测 12 秒的窗口会拖到
**14.9 秒**才超时。改用循环外的 `time.NewTimer` 后精确 12.006 秒。

### ③ pyncmd 被全局 5 秒响应头超时误杀

`network/network.go` 的 `Transport` 写死 `ResponseHeaderTimeout: 5s`。这个值是按
kuwo/kugou 这类快音源定的，但 pyncmd 的第三方 API 实测要 **4.5~9.4 秒**才回响应头，
于是每次都被截断并触发重试，在窗口内一次都拿不到（日志：`http2: timeout awaiting
response headers`）。

修法是给 `ClientRequest` 增加 `ResponseHeaderTimeout` 字段，只有 pyncmd 单独放宽
（见 ⑥），其它音源仍走全局 5 秒，不会被慢接口拖累。同时 `maxAttempts`
从 3 降到 2 —— 单次已经要等十几秒，重试多了必然超出窗口。

### ⑥ pyncmd 走本机代理（2026-11-01 追加）

pyncmd 的第三方 API 直连表现很不稳定：

| 方式 | 实测耗时 | 备注 |
|---|---|---|
| 直连 | 1.2s / 3.3s / 2.9s，随后**挂起** | 也会出现 12.4s、17.9s（`pyncmd consumed: 17.907148332s`） |
| 走本机 Clash `127.0.0.1:7890` | **0.71s / 0.52s / 1.11s** | 全部 200，不挂 |

直连那几个十几秒的样本正好卡在窗口边界上，这就是「同一首歌时好时坏」的直接原因。

所以改成**启动时探测一次本机代理端口**：

- 探测到（`7890`/`7891`/`1080`/`8118`/`10808`/`20171` 依次试，TCP dial 300ms 超时）
  → pyncmd 全程走代理，单次超时 **6s**（实测 0.5~1.1s，6s 已经绰绰有余）；
- 探测不到 → 全程直连，单次超时 **20s**（覆盖 17.9s 那种慢样本）。

用 `-proxy` 参数控制，页面 `wyybin_proxy` 对应它：留空=自动探测，`none`=强制直连，
或填 `http://127.0.0.1:7890` 指定。

**为什么不在每次请求时探测**：每次播放多一次 dial，而端口状态运行中很少变。

**为什么不用 `HTTP_PROXY` 环境变量**：那个变量会影响所有请求，包括 kuwo/kugou
这些本来就快、走代理反而更慢的音源。这里只对 pyncmd 一条通道生效。

**踩过的坑：`ForceAttemptHTTP2` 千万别关。**
一开始想着「代理做 CONNECT 隧道再协商 h2 容易卡」，把它设成了 `false`，结果每次请求都报：

```
net/http: HTTP/1.x transport connection broken:
malformed HTTP response "\x00\x00\x12\x04\x00\x00..."
```

`\x00\x00\x12\x04` 是 h2 帧头 —— 代理在隧道里直接发 h2 帧，Go 却按 HTTP/1.x 解析明文响应。
保持默认的 `true`，让 Go 走 h2 客户端，一切正常。

**注意**：代理这条路依赖 ShellCrash（或其他代理客户端）持续运行。它一停，探测到的端口就没了，
下次启动会回落到直连（20s 超时，慢但能用）。

### ④ 匹配阈值：0.75 是刻意的，不要调低

`CalScore` 公式为 `歌名分*0.55 + 歌手分*0.35 + 首位加分*0.1`，另加歌名必须
≥0.7 的硬门槛。实测《晴天》的搜源行为：

| 搜索关键词 | 前 30 条结果 |
|---|---|
| `晴天`（不带歌手） | 第 1 条就是 **周杰伦 - 晴天**（`MUSIC_228908`） |
| `晴天 周杰伦`（程序实际用的） | **全是翻唱**：`(KTV版伴奏)`、`(原唱:周杰伦)激情吃力版`、`（吉他弹唱）Cover 周杰伦`……原唱根本不在结果里 |

所以「有原唱却播翻唱」不是解析 bug，而是酷我搜索本身的行为：**带歌手搜反而把原唱挤掉**。
翻唱能命中歌名但歌手上完全不匹配，得分约 0.64，被 0.75 阈值正确拦下。

这是有意的取舍（宁缺勿错）：放错歌比没歌更难受。页面 `wyybin_minscore` 可调，
但**不建议低于 0.7**。

### ⑤ 其它

| 文件 | 修复 |
|---|---|
| `proxy/proxy.go` | TLS 证书缺失时改为 `-insecure` 明文监听，不再 `panic`（上游 `startTlsServer` 失败直接 panic，且 `recover` 只在主 goroutine 有效） |
| `provider/kuwo/kuwo.go` | 扫描范围由 `min(len/2+1,5)` 放宽到 `kuwoMaxScan`，原唱被伴奏顶到第 6 条以后也能捞到 |
| `network/network.go` | `ClientRequest` 新增 `HTTPProxy` 字段，可按单条请求指定代理；与 `ResponseHeaderTimeout` 合并成一次 `Transport.Clone()`（分两次写会互相覆盖） |
| `config/config.go` | 新增 `-proxy` 参数与 `resolveProxy()` 端口探测；`common.ProxyAddr` 保存结果供 pyncmd 读取 |

### 真机验证结论（NEWIFI3 / 192.168.3.1，2026-11-01）

| 项 | 结果 |
|---|---|
| go1.26 产物 | `futexwakeup returned -89` + SIGSEGV，**不可用** |
| go1.22.12 + UPX | 7,340,198 → **1,764,092 B（24.0%）**，`-v` rc=0，正常监听 |
| 代理探测 | 日志 `pyncmd 将经代理访问：http://127.0.0.1:7890` |
| 有版权的歌（代理下） | 347230 / 1901371647 各 **2 秒**返回 `br=320`；1901371648 **0 秒** |
| 有版权的歌（`-proxy none`） | 5 秒返回 `br=320`（直连，20s 超时未触发） |
| 无版权的歌（晴天 186016） | 20 秒返回空，日志 `reject low score 0.64 < 0.75` |
| 连测 10 首 | 8 首有版权的全部 0~2 秒成功；1 首无版权等满 20 秒 |
| 并发 10 路 | **0 次** `fatal error` / `concurrent map` / `panic`，进程存活 |
| 定时器精度 | `resolve timeout, got: 20.0102779s`（窗口 20s，循环外建定时器） |

## 补丁 0001 改了什么

### 路由分发（`proxy/proxy.go`，改动最大）

上游把整段路由写成一个 `if / else if / else` 链，且最后的「普通转发」分支挂在了
`else if (isEmbeddedSourceUrl)` 里面 —— 外层条件为假时永远进不去，真正的 API 请求
（`/eapi/...`、`/api/...`）直接掉到函数末尾返回 **200 空响应**。已重写为 `switch` 分派：

```go
func (h *HttpHandler) ServeHTTP(resp, request)   // 分派
func (h *HttpHandler) serveSourceUrl(...)        // /unblockmusic/<realUrl> 解包转发
func (h *HttpHandler) serveTunnel(...)           // CONNECT
func (h *HttpHandler) serveProxy(...)            // 普通请求主路径
```

`serveProxy` 里原本有两处 `if *config.Mode != 1 { proxyDomain = hostStr }`：非 hosts 模式下
不换 IP，而宿主机 DNS 常把 `music.163.com` 解析到 `127.0.0.1`，必然连本机失败。
已改为**无条件**使用 `common.HostDomain` 内置 IP。

### 解锁链路

| 文件 | 修复 |
|---|---|
| `app.go` | `provider.Init()` 必须在 `proxy.InitProxy()` **之前**。上游顺序反了，而 `InitProxy()` 最后一步是同步阻塞的 `startServer()`，导致 provider 表永远是空的 → 所有解锁请求静默 6 秒超时后返回 404 |
| `processor/processor.go` | eapi 请求体解析加长度/分隔符校验（原来 hex 解码失败就 index out of range）；`-e` 模式生成的 URL 由本进程自己接住，避免 hosts 回环依赖 |
| `provider/base/base.go` | 新增 `FilterByScore`：匹配分数低于阈值直接丢弃，宁可空结果也不返回翻唱 |
| `provider/provider.go` | `ParseSong` 路径也要过阈值（原唱走的正是这条路，不经过 `SearchSongFromAllSource`）；provider 表为空时兜底注册 `kuwo` |
| `provider/kuwo/kuwo.go` | 音质按 `MINFO` 实际可用档位选（`format:mp3 & bitrate:320` 才要 320k），修掉「请求 320k 实际降级到 128k」 |
| `config/config.go` | 新增 `-ms` 阈值参数；`common.Source` 重复追加修复 |
| `common/common.go` | 音源列表去重支持 |
| `host/host.go` | `HostDomain` 解析失败时回退到内置 IP 而不是 panic |

## 协议

上游为 MIT，见 `UnblockNeteaseMusic-<commit>/LICENSE`（解包后存在）。
本目录的适配补丁与脚本同样按 MIT 分发。上游版权归 cnsilvan 及贡献者所有。
