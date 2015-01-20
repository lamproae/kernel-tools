KERNEL ?=		3.18-std
-include $(KERNEL)/include.mk

# Default variables
KERNEL_VERSION ?=	$(shell echo $(KERNEL) | cut -d- -f1)
KERNEL_FLAVOR ?=	$(shell echo $(KERNEL) | cut -d- -f2)
KERNEL_FULL ?=		$(KERNEL_VERSION)-$(KERNEL_FLAVOR)
DOCKER_BUILDER ?=	moul/kernel-builder:$(KERNEL_VERSION)-cross-armhf
ARCH_CONFIG ?=		mvebu_v7
CONCURRENCY_LEVEL ?=	$(shell grep -m1 cpu\ cores /proc/cpuinfo 2>/dev/null | sed 's/[^0-9]//g' | grep '[0-9]' || sysctl hw.ncpu | sed 's/[^0-9]//g' | grep '[0-9]')
J ?=			-j $(CONCURRENCY_LEVEL)
S3_TARGET ?=		s3://$(shell whoami)/$(KERNEL_FULL)/

DOCKER_ENV ?=		-e LOADADDR=0x8000 \
			-e CONCURRENCY_LEVEL=$(CONCURRENCY_LEVEL)

LINUX_PATH=/usr/src/linux
DOCKER_VOLUMES ?=	-v $(PWD)/$(KERNEL)/.config:/tmp/.config \
			-v $(PWD)/dist/$(KERNEL_FULL):$(LINUX_PATH)/build/ \
			-v $(PWD)/ccache:/ccache \
			-v $(PWD)/patches:$(LINUX_PATH)/patches \
			-v $(PWD)/$(KERNEL)/patch.sh:$(LINUX_PATH)/patch.sh
DOCKER_RUN_OPTS ?=	-it --rm
IS_LSP ?=		0


all:	build


shell:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash


menuconfig:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash -xec ' \
			cp /tmp/.config .config && \
			if [ -f patch.sh ]; then /bin/bash -xe patch.sh; fi && \
			make menuconfig && \
			cp .config /tmp/.config \
		'


defconfig:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash -xec ' \
			cp /tmp/.config .config && \
			if [ -f patch.sh ]; then /bin/bash -xe patch.sh; fi && \
			make $(ARCH_CONFIG)_defconfig && \
			cp .config /tmp/.config \
		'


oldconfig:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash -xec ' \
			cp /tmp/.config .config && \
			if [ -f patch.sh ]; then /bin/bash -xe patch.sh; fi && \
			make oldconfig && \
			cp .config /tmp/.config \
		'


build:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash -xec ' \
			cp /tmp/.config .config && \
			if [ -f patch.sh ]; then /bin/bash -xe patch.sh; fi && \
			make $(J) uImage && \
			make $(J) modules && \
			make headers_install INSTALL_HDR_PATH=build && \
			make modules_install INSTALL_MOD_PATH=build && \
			make uinstall INSTALL_PATH=build && \
			cp arch/arm/boot/uImage build/uImage-`cat include/config/kernel.release` && \
			( echo "=== $(KERNEL_FULL) - built on `date`" && \
			  echo "=== gcc version" && \
			  gcc --version && \
			  echo "=== file listing" && \
			  find build -type f -ls && \
			  echo "=== sizes" && \
			  du -sh build/* \
			) > build/build.txt \
		'


publish_all: dist/$(KERNEL_FULL)/lib.tar.gz dist/$(KERNEL_FULL)/include.tar.gz
	s3cmd put --acl-public dist/$(KERNEL_FULL)/lib.tar.gz $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/include.tar.gz $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/uImage* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/config* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/vmlinuz* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/build.txt $(S3_TARGET)


dist/$(KERNEL_FULL)/lib.tar.gz: dist/$(KERNEL_FULL)/lib
	tar -C dist/$(KERNEL_FULL) -cvzf $@ lib


dist/$(KERNEL_FULL)/include.tar.gz: dist/$(KERNEL_FULL)/include
	tar -C dist/$(KERNEL_FULL) -cvzf $@ include


ccache_stats:
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		ccache -s


diff:
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(DOCKER_BUILDER) \
		/bin/bash -xec ' \
			make $(ARCH_CONFIG)_defconfig && \
			mv .config .defconfig && \
			cp /tmp/.config .config && \
			diff <(<.defconfig grep "^[^#]" | sort) <(<.config grep "^[^#]" | sort) \
		'


qemu:
	qemu-system-arm \
		-M versatilepb \
		-m 256 \
		-initrd ./dist/$(KERNEL_FULL)/initrd.img-* \
		-kernel ./dist/$(KERNEL_FULL)/uImage-* \
		-append "console=tty1"

clean:
	rm -rf dist/$(KERNEL_FULL)


fclean:	clean
	rm -rf dist ccache


local_assets: $(KERNEL)/.config $(KERNEL)/patch.sh dist/$(KERNEL_FULL)/ ccache


$(KERNEL)/patch.sh:
	mkdir -p $(KERNEL)
	touch $(KERNEL)/patch.sh
	chmod +x $(KERNEL)/patch.sh


$(KERNEL)/.config:
	mkdir -p $(KERNEL)
	touch $(KERNEL)/.config


dist/$(KERNEL_FULL) ccache:
	mkdir -p $@


.PHONY:	all build run menuconfig build clean fclean ccache_stats


## Travis
travis_common:
	#for file in */.config; do bash -n $$file; done
	find . -name "*.bash" | xargs bash -n
	make -n

tools/docker-checkconfig.sh:
	curl -sLo $@ https://raw.githubusercontent.com/docker/docker/master/contrib/check-config.sh
	chmod +x $@

tools/lxc-checkconfig.sh:
	curl -sLo $@ https://raw.githubusercontent.com/dotcloud/lxc/master/src/lxc/lxc-checkconfig.in
	chmod +x $@

travis_kernel:	local_assets travis_prepare tools/lxc-checkconfig.sh tools/docker-checkconfig.sh
	bash -n $(KERNEL)/.config

	# Optional checks, these checks won't fail but we can see the detail in the Travis build result
	CONFIG=$(KERNEL)/.config GREP=grep ./tools/lxc-checkconfig.sh || true
	CONFIG=$(KERNEL)/.config ./tools/docker-checkconfig.sh || true

	# Mandatory check for the non-LSP kernels
	CONFIG=$(KERNEL)/.config LSP=$(LSP) ./tools/c1-checkconfig.sh

	# Disabling make oldconfig check for now because of the memory limit on travis CI builds
	# ./run $(MAKE) oldconfig

# Docker in Travis toolsuite
travis_prepare:	./run
./run:
	# Disabled for now (see travis_kernel below)
	# curl -sLo - https://github.com/moul/travis-docker/raw/master/install.sh | sh -xe
	exit 0
