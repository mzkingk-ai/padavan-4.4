SMARTDNS_VER = Release48.4
SRC_NAME = smartdns-$(SMARTDNS_VER)
SRC_URL=https://github.com/pymumu/smartdns/archive/refs/tags/$(SMARTDNS_VER).tar.gz

THISDIR = $(shell pwd)

# smartdns 48.x 使用 64 位原子操作，mips32 上链接器会带上 libatomic.so.1；
# 该库不在 padavan 默认 romfs 中，需要随包安装到 /lib，否则路由器上
# 启动时直接报 "can't load library 'libatomic.so.1'"。
#
# 注意：这里刻意用通配符而不是 $(shell $(CC) -print-file-name=...)，
# 后者在驱动原生 gcc（非交叉工具链）时返回的仍是非空字符串的库名，
# "找不到库却照样 romfs 进一个不存在的文件" 会静默通过。
#
# $(TOOLCHAIN_DIR) 只在顶层 Makefile 定义，trunk 子 make 不继承（实测为空），
# 因此回落到已导出的 CONFIG_CROSS_COMPILER_ROOT（.../toolchain-mipsel/toolchain-4.4.x，
# 去掉末段 toolchain-4.4.x 即为所需目录）。
SMARTDNS_TC_DIR = $(if $(TOOLCHAIN_DIR),$(TOOLCHAIN_DIR),$(patsubst %/toolchain-4.4.x,%,$(CONFIG_CROSS_COMPILER_ROOT)))

LIBATOMIC_WILDCARDS = \
	$(SMARTDNS_TC_DIR)/toolchain-*/*/sysroot/lib/libatomic.so.1.* \
	$(SMARTDNS_TC_DIR)/toolchain-*/lib/gcc/*/*/libatomic.so.1 \
	$(SMARTDNS_TC_DIR)/toolchain-*/*/sysroot/lib/libatomic.so.1

# 优先取 sysroot 里的真实文件（libatomic.so.1.N），否则取 libatomic.so.1
LIBATOMIC = $(firstword $(sort $(wildcard $(LIBATOMIC_WILDCARDS))))
# 通配符可能匹配到软链接，统一解析成真实文件
LIBATOMIC_REAL = $(realpath $(LIBATOMIC))

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME) NO_GIT_VER=1 VER=$(SMARTDNS_VER)

download_test:
	( if [ ! -f $(THISDIR)/$(SRC_NAME).tar.gz ]; then \
		wget -t5 --timeout=20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL); \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		mkdir $(SRC_NAME); \
		tar zxf $(SRC_NAME).tar.gz --strip-components=1 -C $(SRC_NAME) ; \
	fi )

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		touch config_done; \
	fi )

clean:
	if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME) clean ; \
	fi ; \
	rm -f config_done

romfs:
	$(ROMFSINST) -p +x $(THISDIR)/$(SRC_NAME)/src/smartdns /usr/bin/smartdns
	$(ROMFSINST) -p +x $(THISDIR)/smartdns.sh /usr/bin/smartdns.sh
	$(ROMFSINST) /etc_ro/smartdns_address.conf
	$(ROMFSINST) /etc_ro/smartdns_blacklist-ip.conf
	$(ROMFSINST) /etc_ro/smartdns_custom.conf
	$(ROMFSINST) /etc_ro/smartdns_whitelist-ip.conf
	@if [ -n "$(LIBATOMIC_REAL)" ] && [ -f "$(LIBATOMIC_REAL)" ] ; then \
		echo "smartdns: install libatomic from $(LIBATOMIC_REAL)" ; \
		$(ROMFSINST) -p +x $(LIBATOMIC_REAL) /lib/libatomic.so.1 ; \
	elif [ -f "$(LIBATOMIC)" ] ; then \
		echo "smartdns: install libatomic from $(LIBATOMIC)" ; \
		$(ROMFSINST) -p +x $(LIBATOMIC) /lib/libatomic.so.1 ; \
	else \
		echo "ERROR: libatomic.so.1 not found under $(SMARTDNS_TC_DIR)/toolchain-*" >&2 ; \
		echo "       smartdns binary links against libatomic.so.1 and will NOT start without it." >&2 ; \
		exit 1 ; \
	fi
