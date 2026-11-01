# UnblockNeteaseMusic (Go 版, mzkingk-ai fork)
#   - 上游 cnsilvan 只发布到 0.2.13 (2021)，之后的功能都以源码形式存在 master 分支。
#   - 早期做法是下载固定 commit 的 tar.gz 再叠加一串本地补丁。那个模式的问题是：
#     补丁越叠越多、每次改代码都要重新生成 diff、补丁打崩了还只能靠 .rej 事后兜底。
#   - 现在改为直接从 fork 拉最新源码编译，所有代码改动都在上游仓库里维护，
#     本目录只保留 padavan 特有的适配（守护脚本、Go 版本约束、交叉编译参数）。
#
# 换源码分支/提交：改 UNM_REPO / UNM_REF 即可。
#   UNM_REF 留空 = 跟 master 最新；填 commit 或 tag = 钉住版本，便于复现旧固件。

UNM_VER := 0.2.13
UNM_REPO := https://github.com/mzkingk-ai/UnblockNeteaseMusic.git
UNM_REF :=
UNM_SRC := UnblockNeteaseMusic-src

THISDIR = $(shell pwd)

# 必须出现在任何规则之前：Makefile 里第一条规则会变成默认目标，
# 而下面第一条是核心清理用的 coreclean，不写这行裸跑 make 就只做清理不编译。
.DEFAULT_GOAL := all

# 编译中途被 kill 时工具链会在包目录留下 core.NNNN（每个约 4.8MB），
# 编译前后各清一次，避免越积越多。
coreclean:
	@rm -f $(THISDIR)/core.* $(THISDIR)/bin/*.tmp $(THISDIR)/bin/*.raw

all: coreclean fetch_src build

# 拉取或更新源码。
#
# 有意做成「已经存在就原地 fetch + 重置」，而不是每次都删掉重来：
# 全量克隆一次约几十 MB，而固件构建链会在多个 stage 里多次调用本包，
# 每次重新克隆会把构建时间拖到不可接受。
#
# fetch 失败（断网、GitHub 抽风）时如果本地已有旧源码就直接用，不中断整个
# 固件构建——固件构建链条很长，不该因为一个可选组件拉不到就全盘失败。
fetch_src:
	@set -e ; \
	if [ -d $(THISDIR)/$(UNM_SRC)/.git ] ; then \
		cd $(THISDIR)/$(UNM_SRC) ; \
		if git fetch --depth=1 origin $(if $(UNM_REF),$(UNM_REF),master) 2>/dev/null ; then \
			git reset --hard FETCH_HEAD >/dev/null ; \
			echo "UnblockNeteaseMusic: updated to $$(git rev-parse --short HEAD)" ; \
		else \
			echo "WARNING: 拉取失败，沿用本地已缓存源码 $$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" ; \
		fi ; \
	else \
		echo "Cloning UnblockNeteaseMusic from $(UNM_REPO)" ; \
		rm -rf $(THISDIR)/$(UNM_SRC) ; \
		git clone --depth=1 $(if $(UNM_REF),--branch $(UNM_REF),) \
			$(UNM_REPO) $(THISDIR)/$(UNM_SRC) ; \
	fi

# 三条硬约束（都是真机试出来的，别改回去）：
#
# 1) 编译器必须是 go1.22。go1.23+ 的 runtime 用 lock_spinbit 自旋锁，在 MT7621
#    上让 futex 返回 -89，产物一启动就 SIGSEGV（PC=0x77c00 runtime.futexwakeup）。
#
# 2) 【当前暂停 UPX 压缩】UNM_UPX_ENABLE := n
#    压缩本身有效（7.34MB -> 1.76MB，固件少约 1.37MB），且压缩版曾在
#    NEWIFI3(D2) / 4.4.198 上真机验过 -v 与 :18080 代理。
#    但 2026-11-01 完整固件构建时，upx 在 make 子进程里稳定 SIGSEGV
#    （单独跑同一条命令 8/8 通过；core 显示崩在 upx 静态二进制的 startup 段，
#    RSP/RIP 落在栈与代码段之外，是 upx 自身 memcpy 到坏地址，与输入文件无关）。
#    在查清之前先关掉，产物保持未压缩的 7.34MB。
#    想恢复：把下面的 UNM_UPX_ENABLE 改成 y 即可，其余逻辑都在。
#
# 3) 字节序：MT7621 是 MIPS32r2 **小端**（工具链 mipsel-*、固件里 smartdns/dnsmasq/
#    libuClibc 全是 LSB）。Go 的 GOARCH=mips 产出的是**大端**，上机会 exec format error，
#    必须用 mipsle。
#
# UPX 必须在这一步做，不能只手工压 bin/UnblockNeteaseMusic：
# 本包每次构建都会重跑 go build 覆盖 bin/，手工压过的版本会被冲掉。
# 优先用 PATH 上的 upx；宿主的 ~/.local/bin 在容器内不可见（没挂载），
# 所以回退到随源码提交的静态版 trunk/tools/bin/upx。
UNM_UPX_ENABLE := n
UNM_UPX := $$(command -v upx || echo $(THISDIR)/../../tools/bin/upx)

build:
	( cd $(THISDIR)/$(UNM_SRC) ; \
		GO_VER=$$(go version | sed -E 's/.*go([0-9]+)\.([0-9]+).*/\1 \2/'); \
		GO_MAJ=$$(echo $$GO_VER | cut -d" " -f1); \
		GO_MIN=$$(echo $$GO_VER | cut -d" " -f2); \
		if [ "$$GO_MAJ" -gt 1 ] || { [ "$$GO_MAJ" -eq 1 ] && [ "$$GO_MIN" -ge 23 ]; }; then \
			echo "ERROR: 必须用 go1.22 编译（当前 $$(go version)）。"; \
			echo "       go1.23+ 的 runtime 自旋锁在 MT7621 上会让 futex 返回 -89，"; \
			echo "       产物一启动就 SIGSEGV（PC=0x77c00 runtime.futexwakeup）。"; \
			exit 1; \
		fi; \
		GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 \
		go build -trimpath \
			-ldflags "-s -w -buildid= -X github.com/cnsilvan/UnblockNeteaseMusic/version.Version=$(UNM_VER) -X github.com/cnsilvan/UnblockNeteaseMusic/version.GitCommit=$$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
			-o $(THISDIR)/bin/UnblockNeteaseMusic . ; \
	)
	@echo "built: $$(stat -c %s $(THISDIR)/bin/UnblockNeteaseMusic) bytes"
ifeq ($(UNM_UPX_ENABLE),y)
	$(UNM_UPX) -9 --lzma $(THISDIR)/bin/UnblockNeteaseMusic
	@echo "packed: $$(stat -c %s $(THISDIR)/bin/UnblockNeteaseMusic) bytes"
else
	@echo "packed: skipped (UNM_UPX_ENABLE=n)"
endif

clean:
	rm -rf $(THISDIR)/$(UNM_SRC)
	rm -rf $(THISDIR)/bin
	rm -f $(THISDIR)/core.*
	rm -rf $(THISDIR)/tools

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/bin/UnblockNeteaseMusic /usr/bin/UnblockNeteaseMusic
	$(ROMFSINST) -p +x $(THISDIR)/unblockneteasemusic.sh /usr/bin/unblockneteasemusic.sh
	$(ROMFSINST) $(THISDIR)/README.md /etc/UnblockNeteaseMusic.md
	#
	# 出厂默认证书套装。
	# 装到 /etc/unm-cert-default 而不是直接进 /etc/storage：
	# /etc/storage 是 mtd_storage.sh 管理的持久化分区，
	# 用 tar 把整个目录打个包写 flash，里面没有的文件刷固件后就没了。
	# 由 /sbin/mtd_storage.sh 的 func_fill（dev_init.sh 每次开机调用
	# `mtd_storage.sh fill`）在「目标目录不存在」时拷过去 ——
	# 已经存在的绝不覆盖，所以用户自己的证书和已经装过的客户端 CA 不受影响。
	#
	# 注意要先建目录：ROMFSINST 只是 cp，romfs 里没有 /etc/unm-cert-default
	# 这个目录就会直接报 "No such file or directory"。
	# （不能用 ROMFSINST -d：那个 -d 是「src 是目录、整棵拷过去」的意思，
	#   传一个不存在的 src 反而报 cp: cannot stat。）
	@mkdir -p $(ROMFSDIR)/etc/unm-cert-default
	$(ROMFSINST) -p 644 $(THISDIR)/cert/ca.crt /etc/unm-cert-default/ca.crt
	$(ROMFSINST) -p 600 $(THISDIR)/cert/ca.key /etc/unm-cert-default/ca.key
	$(ROMFSINST) -p 644 $(THISDIR)/cert/server.crt /etc/unm-cert-default/server.crt
	$(ROMFSINST) -p 600 $(THISDIR)/cert/server.key /etc/unm-cert-default/server.key
