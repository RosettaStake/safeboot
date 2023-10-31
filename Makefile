VERSION ?= 0.8

GIT_DIRTY := $(shell if git status -s >/dev/null ; then echo dirty ; else echo clean ; fi)
GIT_HASH  := $(shell git rev-parse HEAD)
TOP := $(shell pwd)

BINS += bin/sbsign.safeboot
BINS += bin/sign-efi-sig-list.safeboot
BINS += bin/tpm2-totp
BINS += bin/tpm2

all: $(BINS)

#
# sbsign needs to be built from a patched version to avoid a
# segfault when using the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += sbsigntools
bin/sbsign.safeboot: sbsigntools/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
	cp $(dir $<)src/sbsign $@
sbsigntools/Makefile: sbsigntools/autogen.sh
	cd $(dir $@) ; ./autogen.sh && ./configure
sbsigntools/autogen.sh:
	git submodule update --init --recursive --recommend-shallow sbsigntools

#
# sign-efi-sig-list needs to be built from source to have support for
# the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += efitools
bin/sign-efi-sig-list.safeboot: efitools/Makefile
	$(MAKE) -C $(dir $<) sign-efi-sig-list
	mkdir -p $(dir $@)
	cp $(dir $<)sign-efi-sig-list $@
efitools/Makefile:
	git submodule update --init --recursive --recommend-shallow efitools

#
# tpm2-tss is the library used by tpm2-tools
#
SUBMODULES += tpm2-tss

libtss2-include = -I$(TOP)/tpm2-tss/include
libtss2-mu = $(TOP)/build/tpm2-tss/src/tss2-mu/.libs/libtss2-mu.a
libtss2-rc = $(TOP)/build/tpm2-tss/src/tss2-rc/.libs/libtss2-rc.a
libtss2-sys = $(TOP)/build/tpm2-tss/src/tss2-sys/.libs/libtss2-sys.a
libtss2-esys = $(TOP)/build/tpm2-tss/src/tss2-esys/.libs/libtss2-esys.a
libtss2-tcti = $(TOP)/build/tpm2-tss/src/tss2-tcti/.libs/libtss2-tctildr.a

tpm2-tss/bootstrap:
	mkdir -p $(dir $@)
	git submodule update --init --recursive --recommend-shallow $(dir $@)
tpm2-tss/configure: tpm2-tss/bootstrap
	cd $(dir $@) ; ./bootstrap
build/tpm2-tss/Makefile: tpm2-tss/configure
	mkdir -p $(dir $@)
	cd $(dir $@) ; ../../tpm2-tss/configure \
		--disable-doxygen-doc \

$(libtss2-esys): build/tpm2-tss/Makefile
	$(MAKE) -C $(dir $<)

#
# tpm2-tools is the head after bundling and ecc support built in
#
SUBMODULES += tpm2-tools

tpm2-tools/bootstrap:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
tpm2-tools/configure: tpm2-tools/bootstrap
	cd $(dir $@) ; ./bootstrap
build/tpm2-tools/Makefile: tpm2-tools/configure $(libtss2-esys)
	mkdir -p $(dir $@)
	cd $(dir $@) ; ../../tpm2-tools/configure \
		TSS2_RC_CFLAGS=$(libtss2-include) \
		TSS2_RC_LIBS="$(libtss2-rc)" \
		TSS2_MU_CFLAGS=$(libtss2-include) \
		TSS2_MU_LIBS="$(libtss2-mu)" \
		TSS2_SYS_CFLAGS=$(libtss2-include) \
		TSS2_SYS_LIBS="$(libtss2-sys)" \
		TSS2_TCTILDR_CFLAGS=$(libtss2-include) \
		TSS2_TCTILDR_LIBS="$(libtss2-tcti)" \
		TSS2_ESYS_3_0_CFLAGS=$(libtss2-include) \
		TSS2_ESYS_3_0_LIBS="$(libtss2-esys) -ldl" \

build/tpm2-tools/tools/tpm2: build/tpm2-tools/Makefile
	$(MAKE) -C $(dir $<)

bin/tpm2: build/tpm2-tools/tools/tpm2
	mkdir -p $(dir $@)
	cp $< $@


#
# tpm2-totp is build from a branch with hostname support
#
SUBMODULES += tpm2-totp
tpm2-totp/bootstrap:
	git submodule update --init --recursive --recommend-shallow tpm2-totp
tpm2-totp/configure: tpm2-totp/bootstrap
	cd $(dir $@) ; ./bootstrap
build/tpm2-totp/Makefile: tpm2-totp/configure $(libtss2-esys)
	mkdir -p $(dir $@)
	cd $(dir $@) && $(TOP)/$< \
		TSS2_MU_CFLAGS=-I../tpm2-tss/include \
		TSS2_MU_LIBS="$(libtss2-mu)" \
		TSS2_TCTILDR_CFLAGS=$(libtss2-include) \
		TSS2_TCTILDR_LIBS="$(libtss2-tcti)" \
		TSS2_TCTI_DEVICE_LIBDIR="$(dir $(libtss2-tcti))" \
		TSS2_ESYS_CFLAGS=$(libtss2-include) \
		TSS2_ESYS_LIBS="$(libtss2-esys) $(libtss2-sys) -lssl -lcrypto -ldl" \

build/tpm2-totp/tpm2-totp: build/tpm2-totp/Makefile
	$(MAKE) -C $(dir $<)
bin/tpm2-totp: build/tpm2-totp/tpm2-totp
	mkdir -p $(dir $@)
	cp $< $@


#
# Extra package building requirements
#
requirements: | build
	DEBIAN_FRONTEND=noninteractive \
	apt install -y \
		devscripts \
		debhelper \
		efitools \
		gnu-efi \
		build-essential \
		binutils-dev \
		git \
		pkg-config \
		automake \
		autoconf \
		autoconf-archive \
		initramfs-tools \
		help2man \
		libssl-dev \
		uuid \
		uuid-runtime \
		shellcheck \
		curl \
		libjson-c-dev \
		libcurl4-openssl-dev \

# Remove the temporary files and build stuff
clean:
	rm -rf bin $(SUBMODULES) build
	mkdir $(SUBMODULES)
	#git submodule update --init --recursive --recommend-shallow 

# Regenerate the source file
tar: clean
	tar zcvf ../safeboot_$(VERSION).orig.tar.gz \
		--exclude .git \
		--exclude debian \
		.

package: tar
	debuild -uc -us
	cp ../safeboot_$(VERSION)-1_amd64.deb safeboot-unstable.deb


# Run shellcheck on the scripts
shellcheck:
	for file in \
		sbin/safeboot* \
		initramfs/*/* \
	; do \
		shellcheck $$file functions.sh ; \
	done

# Fake an overlay mount to replace files in /etc/safeboot with these
fake-mount:
	mount --bind `pwd`/safeboot.conf /etc/safeboot/safeboot.conf
	mount --bind `pwd`/functions.sh /etc/safeboot/functions.sh
	mount --bind `pwd`/sbin/safeboot /sbin/safeboot
	mount --bind `pwd`/sbin/safeboot-tpm-unseal /sbin/safeboot-tpm-unseal
	mount --bind `pwd`/initramfs/scripts/safeboot-bootmode /etc/initramfs-tools/scripts/init-top/safeboot-bootmode
fake-unmount:
	mount | awk '/safeboot/ { print $$3 }' | xargs umount


build:
	mkdir -p $@
