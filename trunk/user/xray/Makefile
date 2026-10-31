XRAY_VERSION := 1.8.24
XRAY_URL := https://codeload.github.com/XTLS/Xray-core/tar.gz/v$(XRAY_VERSION)
XRAY_DIR = xray-core/Xray-core-$(XRAY_VERSION)/main

THISDIR = $(shell pwd)

# UPX 在 build 末尾就地压缩，不能只手工压 bin/xray —— 每次 make 都会重跑 go build 覆盖掉。
# 容器里 PATH 上没有 upx 时回落到随源码提交的静态版（宿主机 ~/.local 不在容器挂载内）。
XRAY_UPX := $$(command -v upx || echo $(THISDIR)/../../tools/bin/upx)

# go1.23+ 的 runtime 自旋锁在 MT7621 上让 futex 返回 -89，产物一启动就 SIGSEGV。
# 注意为修此问题可以把 go 钉在 1.22，但不要把 go.mod 的 go 指令抬到 1.23（见下面 checklinkname）。
GO_VER_CHK := \
	GO_VER=$$(go version | sed -E 's/.*go([0-9]+)\.([0-9]+).*/\1 \2/'); \
	GO_MAJ=$$(echo $$GO_VER | cut -d" " -f1); \
	GO_MIN=$$(echo $$GO_VER | cut -d" " -f2); \
	if [ "$$GO_MAJ" -gt 1 ] || { [ "$$GO_MAJ" -eq 1 ] && [ "$$GO_MIN" -ge 23 ]; }; then \
		echo "ERROR: 必须用 go1.22 编译（当前 $$(go version)）"; \
		exit 1; \
	fi

all: download build_extract build

download:
	( if [ ! -f $(THISDIR)/Xray-core-$(XRAY_VERSION).tar.gz ]; then \
	curl --create-dirs -L $(XRAY_URL) -o $(THISDIR)/Xray-core-$(XRAY_VERSION).tar.gz ; \
	fi )

build_extract:
	mkdir -p $(THISDIR)/xray-core
	mkdir -p $(THISDIR)/bin
	( if [ ! -d $(THISDIR)/xray-core/Xray-core-$(XRAY_VERSION) ]; then \
	rm -rf $(THISDIR)/xray-core/* ; \
	tar zxf $(THISDIR)/Xray-core-$(XRAY_VERSION).tar.gz -C $(THISDIR)/xray-core ; \
	fi )

# 这里绝对不能把 go.mod 的 go 指令抬版本。上游曾用 sed 改成 "go 1.23.0"，后果有两个：
#   1) 触发 go1.23+ 的 runtime 自旋锁问题，产物在 MT7621 上启动即 SIGSEGV；
#   2) xray 1.8.24 依赖的 sagernet/sing v0.4.1 用 //go:linkname 引用 net 包的未导出
#      符号 errNoSuchInterface，Go 1.23 起 linkname 默认只允许显式标记的符号，直接链接失败。
# 正解：留在原生的 "go 1.21.4"，用 go1.22 编。go1.22 的链接器没有 -checklinkname，
# 也不需要它（该限制从 Go 1.23 才引入）。
build:
	( $(GO_VER_CHK) ; \
	cd $(THISDIR)/$(XRAY_DIR) && \
	GOOS=linux GOARCH=mipsle CGO_ENABLED=0 go build -o $(THISDIR)/bin/xray -trimpath \
	-ldflags "-s -w -buildid="; \
	)
	@echo "built:  $$(stat -c %s $(THISDIR)/bin/xray) bytes"
	$(XRAY_UPX) -9 --lzma $(THISDIR)/bin/xray
	@echo "packed: $$(stat -c %s $(THISDIR)/bin/xray) bytes"

clean:
	rm -rf $(THISDIR)/xray-core
	rm -rf $(THISDIR)/bin

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/bin/xray /usr/bin/xray
