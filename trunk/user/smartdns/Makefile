SMARTDNS_VER = Release48.4
SRC_NAME = smartdns-$(SMARTDNS_VER)
SRC_URL=https://github.com/pymumu/smartdns/archive/refs/tags/$(SMARTDNS_VER).tar.gz

THISDIR = $(shell pwd)

# smartdns 48.x 使用 64 位原子操作，mips32 上需要 libatomic；
# 该库不在 padavan 默认 romfs 中，需要随包安装到 /lib。
LIBATOMIC = $(shell $(CC) -print-file-name=libatomic.so.1 2>/dev/null)

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
	@if [ -f "$(LIBATOMIC)" ] ; then \
		$(ROMFSINST) -p +x $(LIBATOMIC) /lib/libatomic.so.1 ; \
	else \
		echo "ERROR: libatomic.so.1 not found (CC=$(CC)), smartdns will not start" >&2 ; \
		exit 1 ; \
	fi
