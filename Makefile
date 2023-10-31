VERSION ?= 0.8

GIT_DIRTY := $(shell if git status -s >/dev/null ; then echo dirty ; else echo clean ; fi)
GIT_HASH  := $(shell git rev-parse HEAD)
TOP := $(shell pwd)

BINS += bin/sbsign.safeboot

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
# Extra package building requirements
#
requirements: | build
	DEBIAN_FRONTEND=noninteractive \
	apt install -y \
		devscripts \
		debhelper \
		efitools \
		tpm2-tools \
		libc6 \
		libssl-dev \
		xxd \
		automake \
		autoconf \
		binutils-dev \
		libssl-dev \
		initramfs-tools \
		curl \
		pkg-config \
		uuid \
		uuid-runtime \
		uuid-dev \
		gnu-efi \
		help2man

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
