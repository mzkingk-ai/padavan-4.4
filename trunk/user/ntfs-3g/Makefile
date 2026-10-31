SRC_NAME=ntfs-3g-2022.10.3
SRC_URL=https://codeload.github.com/tuxera/ntfs-3g/tar.gz/refs/tags/2022.10.3

CFLAGS += -O2 -ffunction-sections -fdata-sections
LDFLAGS += -Wl,--gc-sections

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME)

download_test:
	( if [ ! -f $(SRC_NAME).tar.gz ]; then \
		wget -t5 --timeout=20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL); \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar zxf $(SRC_NAME).tar.gz; \
	fi )
	( for p in patches/*.patch; do \
	    [ -f "$$p" ] || continue; \
	    patch -d $(SRC_NAME) -r - -N -p1 < $$p || echo "  ntfs-3g: $$p 已应用，跳过"; \
	  done )

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		make configure && touch config_done; \
	fi )

configure:
	cd $(SRC_NAME) ; autoreconf -fi --install 2>&1 | grep -v AM_PATH | head -1 ; cd ..
	( cd $(SRC_NAME) ; \
	./configure \
		--prefix=/usr \
		--enable-shared=no \
		--enable-static=no \
		--disable-mtab \
		--disable-debug \
		--disable-library \
		--disable-ldconfig \
		--disable-mount-helper \
		--with-fuse=internal \
		--host=$(HOST_TARGET) \
		--build=$(HOST_BUILD) ; \
	)

clean:
	if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME) distclean ; \
	fi ; \
	rm -f config_done

romfs:
ifeq ($(CONFIG_FIRMWARE_ENABLE_FUSE),y)
ifneq ($(CONFIG_FIRMWARE_ENABLE_UFSD),y)
	$(ROMFSINST) $(SRC_NAME)/src/ntfs-3g /sbin/ntfs-3g
endif
endif
