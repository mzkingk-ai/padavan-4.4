V2RAY_VERSION := 5.31.0
V2RAY_URL := https://codeload.github.com/v2fly/v2ray-core/tar.gz/v$(V2RAY_VERSION)
V2RAY_DIR = "v2ray-core/core/main"

THISDIR = $(shell pwd)

# UPX 在 build 末尾就地压缩（每次 make 都会重跑 go build 覆盖 bin/，所以不能只手工压）。
# PATH 上没有 upx 时回落到随源码提交的静态版（宿主机 ~/.local 不在容器挂载内）。
V2RAY_UPX := $$(command -v upx || echo $(THISDIR)/../../tools/bin/upx)

# go1.23+ 的 runtime 自旋锁在 MT7621 上让 futex 返回 -89，产物一启动就 SIGSEGV。
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
	( if [ ! -f $(THISDIR)/v2ray-core-$(V2RAY_VERSION).tar.gz ]; then \
	curl --create-dirs -L $(V2RAY_URL) -o $(THISDIR)/v2ray-core-$(V2RAY_VERSION).tar.gz ; \
	fi )

build_extract:
	mkdir -p $(THISDIR)/v2ray-core
	mkdir -p $(THISDIR)/bin
	( if [ ! -d $(THISDIR)/v2ray-core/core ]; then \
	tar zxf $(THISDIR)/v2ray-core-$(V2RAY_VERSION).tar.gz -C $(THISDIR)/v2ray-core ; \
	mv $(THISDIR)/v2ray-core/v2ray-core-$(V2RAY_VERSION) $(THISDIR)/v2ray-core/core ; \
	fi )

build:
	( $(GO_VER_CHK) ; \
	cd $(THISDIR)/$(V2RAY_DIR) && \
	GOOS=linux GOARCH=mipsle CGO_ENABLED=0 go build -o $(THISDIR)/bin/v2ray -trimpath -ldflags "-s -w -buildid="; \
	)
	@echo "built:  $$(stat -c %s $(THISDIR)/bin/v2ray) bytes"
	$(V2RAY_UPX) -9 --lzma $(THISDIR)/bin/v2ray
	@echo "packed: $$(stat -c %s $(THISDIR)/bin/v2ray) bytes"

clean:
	rm -rf $(THISDIR)/v2ray-core
	rm -rf $(THISDIR)/bin

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/bin/v2ray /usr/bin/v2ray
