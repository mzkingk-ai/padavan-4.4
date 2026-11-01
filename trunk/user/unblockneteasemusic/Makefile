# UnblockNeteaseMusic (Go 版, cnsilvan fork)
#   - 上游只发布到 0.2.13 (2021)，之后的功能都以源码形式存在 master 分支，
#     故这里从固定 commit 的源码包编译，不再下载 zip 资产。
#   - go.mod 声明 go 1.16，依赖仅 mapstructure + x/text，可离线缓存。

UNM_VER := 0.2.13
UNM_COMMIT := 91afd9361e8bb5308c3a6f8bba39a577eaba76be
UNM_SRC := UnblockNeteaseMusic-$(UNM_COMMIT)
UNM_URL := https://github.com/cnsilvan/UnblockNeteaseMusic/archive/$(UNM_COMMIT).tar.gz

# 本地适配补丁（按文件名顺序应用）：
#   0001 路由分发重写 + 解锁链路修复（音质选档、翻唱阈值、证书失败不退出、eapi 容错、
#        provider 初始化顺序、HostDomain 兜底等），详见 README.md
#   0002 上述修复的回归测试
# 源码目录永远是「干净解包 + 打这两个补丁」，补丁一旦有变重新解包即可，
# 不要在解包目录里裸改代码。
UNM_PATCHES := $(sort $(wildcard $(CURDIR)/patches/*.patch))

THISDIR = $(shell pwd)

# 必须出现在任何规则之前：Makefile 里第一条规则会变成默认目标，
# 而下面第一条是核心清理用的 coreclean，不写这行裸跑 make 就只做清理不编译。
.DEFAULT_GOAL := all

# 编译中途被 kill 时工具链会在包目录留下 core.NNNN（每个约 4.8MB），
# 编译前后各清一次，避免越积越多。
coreclean:
	@rm -f $(THISDIR)/core.* $(THISDIR)/bin/*.tmp $(THISDIR)/bin/*.raw

all: coreclean download_test extract_test patch_test build

download_test:
	( if [ ! -f $(THISDIR)/$(UNM_SRC).tar.gz ]; then \
		echo "Downloading UnblockNeteaseMusic $(UNM_VER) ($(UNM_COMMIT))" ; \
		curl --create-dirs -fL $(UNM_URL) -o $(THISDIR)/$(UNM_SRC).tar.gz ; \
	fi )

extract_test:
	( if [ ! -d $(THISDIR)/$(UNM_SRC) ]; then \
		mkdir -p $(THISDIR)/$(UNM_SRC) ; \
		tar zxf $(THISDIR)/$(UNM_SRC).tar.gz -C $(THISDIR)/$(UNM_SRC) --strip-components=1 ; \
	fi )

# 打补丁。用 --dry-run 探一次：能干净打到 → 说明还是未打过补丁的原始解包，
# 正式应用；打不上 → 认为已经打过（或已被改动），跳过，
# 这样 make 重复执行不会报错，也不会把补丁打第二遍。
patch_test:
	( for p in $(UNM_PATCHES) ; do \
		if patch -p1 -d $(THISDIR)/$(UNM_SRC) --dry-run -s -f -i $$p >/dev/null 2>&1 ; then \
			echo "Applying patch $$(basename $$p)" ; \
			patch -p1 -d $(THISDIR)/$(UNM_SRC) -s -i $$p || exit 1 ; \
		else \
			echo "Patch $$(basename $$p) already applied, skip" ; \
		fi ; \
	done )

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
			-ldflags "-s -w -buildid= -X github.com/cnsilvan/UnblockNeteaseMusic/version.Version=$(UNM_VER) -X github.com/cnsilvan/UnblockNeteaseMusic/version.GitCommit=$(UNM_COMMIT)" \
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
