# Builds the slipmesh Talos system extensions (amneziawg, awg, router, nftables) with
# siderolabs/extensions' own bldr pipeline, then bakes them with talos-kernel's signed kernel into
# a Talos installer image. See README.
#
# Needs Docker with `docker buildx`: bldr is a BuildKit frontend that podman and buildah cannot
# run. build/ is disposable; `make distclean` drops it and the checkouts are fetched again.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# make hands variables set on its command line to every sub-make, through MAKEFLAGS and the
# environment both. The upstream Makefiles this one calls read TAG, REGISTRY and PUSH for their own
# purposes, and talos bakes TAG and REGISTRY into machined: a CI run's TAG=sha-<commit> made the
# installed Talos reject its own config. They get only what each call passes explicitly.
MAKEOVERRIDES :=
unexport $(foreach v,$(.VARIABLES),$(if $(filter command line,$(origin $(v))),$(v)))

_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out help print-config check-pins check-version check-talos-build hashes manifest clean distclean checkout-%,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif

# --- derived pins -------------------------------------------------------------------
TALOS_VERSION           := $(firstword $(subst +, ,$(KERNEL_RELEASE)))
UPSTREAM_EXTENSIONS_REF := $(TALOS_VERSION)
KERNEL_TAG              := $(subst +,-,$(KERNEL_RELEASE))
KERNEL_IMAGE            := ghcr.io/slipmesh/kernel:$(KERNEL_TAG)
AMNEZIAWG_PKG           := ghcr.io/slipmesh/amneziawg-pkg:$(KERNEL_TAG)

# PKGS is a `git describe` string; `git checkout` needs the object id from its tail.
# Abbreviated, so it resolves locally but is never fetchable - see checkout-pkgs.
PKGS_COMMIT := $(lastword $(subst -g, ,$(PKGS)))

BIRD_VERSION   := $(patsubst v%,%,$(BIRD_REV))
DAEMONS_DIGEST := $(lastword $(subst @sha256:, ,$(DAEMONS_IMAGE)))

# --- what this build publishes ------------------------------------------------------
# Every image is tagged with the commit it was built from, so a new build never reuses a tag a
# node may already have pulled.
TAG ?= sha-$(shell git rev-parse HEAD 2>/dev/null)

EXTENSIONS         := amneziawg awg router nftables
EXTENSION_IMAGES   := $(foreach e,$(EXTENSIONS),$(REGISTRY)/$(e):$(TAG)-$(TARGET_ARCH))
NFTABLES_PKG_IMAGE := $(REGISTRY)/nftables-pkg:$(TAG)-$(TARGET_ARCH)
INSTALLER_IMAGE    := $(REGISTRY)/talos-installer:$(TAG)-$(TARGET_ARCH)
MANIFEST_IMAGE     := $(REGISTRY)/talos-installer:$(TAG)
ARCHS              := amd64 arm64

# extensions-validator accepts only a few version shapes: `<semver>-v<talos>`, as zfs upstream
# uses, and `<hex>-v<talos>[-<suffix>]`, whose hex here is the daemons image digest.
DAEMONS_SHORT     := $(shell printf '%.12s' '$(DAEMONS_DIGEST)')
VERSION_amneziawg := $(patsubst v%,%,$(AWG_REF))-$(TALOS_VERSION)
VERSION_awg       := $(DAEMONS_SHORT)-$(TALOS_VERSION)
VERSION_router    := $(DAEMONS_SHORT)-$(TALOS_VERSION)-bird$(BIRD_VERSION)
VERSION_nftables  := $(DAEMONS_SHORT)-$(TALOS_VERSION)-nft$(NFTABLES_VERSION)

# bldr renders every pkg.yaml in the tree whichever target it builds, so each build gets them all.
EXTENSION_ARGS := --build-arg=AMNEZIAWG_PKG=$(AMNEZIAWG_PKG) --build-arg=DAEMONS=$(DAEMONS_IMAGE) \
                  --build-arg=NFTABLES_PKG=$(NFTABLES_PKG_IMAGE) --build-arg=BIRD_REV=$(BIRD_REV) \
                  --build-arg=BIRD_COMMIT=$(BIRD_COMMIT) --build-arg=BIRD_EXPORTER_REV=$(BIRD_EXPORTER_REV)

NFTABLES_PKG_ARGS := \
  --build-arg=LIBMNL_VERSION=$(LIBMNL_VERSION) --build-arg=LIBMNL_SHA256=$(LIBMNL_SHA256) --build-arg=LIBMNL_SHA512=$(LIBMNL_SHA512) \
  --build-arg=LIBNFTNL_VERSION=$(LIBNFTNL_VERSION) --build-arg=LIBNFTNL_SHA256=$(LIBNFTNL_SHA256) --build-arg=LIBNFTNL_SHA512=$(LIBNFTNL_SHA512) \
  --build-arg=NFTABLES_VERSION=$(NFTABLES_VERSION) --build-arg=NFTABLES_SHA256=$(NFTABLES_SHA256) --build-arg=NFTABLES_SHA512=$(NFTABLES_SHA512) \
  --build-arg=MUSL_VERSION=$(MUSL_VERSION) --build-arg=MUSL_SHA256=$(MUSL_SHA256) --build-arg=MUSL_SHA512=$(MUSL_SHA512)

BUILD_DIR      := build
TALOS_DIR      := $(BUILD_DIR)/talos
PKGS_DIR       := $(BUILD_DIR)/pkgs
EXTENSIONS_DIR := $(BUILD_DIR)/extensions
OUT_DIR        := $(BUILD_DIR)/out-$(TARGET_ARCH)

# The imager tool stays the stock siderolabs one; the signed kernel and initramfs are bind-mounted
# over its own at run time (docs/kernel-signing.md). The rootfs, sd-boot and sd-stub come from
# `installer-base`: siderolabs stopped publishing `installer` with Talos 1.14, and installer-base is
# what upstream's own Makefile hands imager as --base-installer-image.
IMAGER            := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
BASE_INSTALLER    := ghcr.io/siderolabs/installer-base:$(TALOS_VERSION)
BASE_OCI_DIR      := $(OUT_DIR)/base-oci
CUSTOM_KERNEL_DIR := $(OUT_DIR)/custom-kernel

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_%-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins and image names.
	@echo "talos            : $(TALOS_VERSION) (from kernel release $(KERNEL_RELEASE))"
	@echo "kernel           : $(KERNEL_IMAGE)"
	@echo "amneziawg-pkg    : $(AMNEZIAWG_PKG) (awg $(AWG_REF))"
	@echo "daemons          : $(DAEMONS_IMAGE)"
	@echo "pkgs             : $(PKGS) (commit $(PKGS_COMMIT))"
	@echo "extensions ref   : $(UPSTREAM_EXTENSIONS_REF)"
	@echo "bird             : $(BIRD_VERSION), bird_exporter $(BIRD_EXPORTER_REV)"
	@echo "nftables         : $(NFTABLES_VERSION) (libnftnl $(LIBNFTNL_VERSION), libmnl $(LIBMNL_VERSION))"
	@echo "target arch      : $(TARGET_ARCH)"
	@$(foreach e,$(EXTENSIONS),printf '%-17s: %s (%s)\n' '$(e)' '$(REGISTRY)/$(e):$(TAG)-$(TARGET_ARCH)' '$(VERSION_$(e))';)
	@echo "nftables-pkg     : $(NFTABLES_PKG_IMAGE)"
	@echo "installer        : $(INSTALLER_IMAGE)"
	@echo "manifest         : $(MANIFEST_IMAGE)"

.PHONY: check-pins
check-pins: ## Assert the pins agree with KERNEL_RELEASE and its Talos release.
	@want=$$(curl -sS --fail "https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs"); \
	if [ "$(PKGS)" != "$$want" ]; then \
	  echo "MISMATCH: PKGS is $(PKGS), Talos $(TALOS_VERSION) was built from pkgs $$want"; exit 1; \
	fi; \
	echo "PKGS matches Talos $(TALOS_VERSION): $$want"
	@want=$$(curl -sS --fail "https://raw.githubusercontent.com/slipmesh/talos-kernel/$(subst +,%2B,$(KERNEL_RELEASE))/versions.env" \
	  | sed -n 's/^AWG_REF=//p'); \
	[ -n "$$want" ] || { echo "talos-kernel $(KERNEL_RELEASE)'s versions.env names no AWG_REF"; exit 1; }; \
	if [ "$(AWG_REF)" != "$$want" ]; then \
	  echo "MISMATCH: AWG_REF is $(AWG_REF), talos-kernel $(KERNEL_RELEASE) built $$want"; exit 1; \
	fi; \
	echo "AWG_REF matches talos-kernel $(KERNEL_RELEASE): $$want"
	@[[ "$(DAEMONS_IMAGE)" =~ @sha256:[0-9a-f]{64}$$ ]] \
	  || { echo "DAEMONS_IMAGE must be pinned by digest: $(DAEMONS_IMAGE)"; exit 1; }
	@echo "DAEMONS_IMAGE pinned by digest"

.PHONY: check-version
check-version: ## Assert VERSION is a release of TALOS_VERSION, vX.Y.Z+sm.N.
	@[[ "$(VERSION)" =~ ^$(subst .,\.,$(TALOS_VERSION))\+sm\.[1-9][0-9]*$$ ]] \
	  || { echo "VERSION must be $(TALOS_VERSION)+sm.<N>, got '$(VERSION)'"; exit 1; }
	@echo "$(VERSION) releases Talos $(TALOS_VERSION)"

# The talos Makefile bakes TAG, REGISTRY and USERNAME into machined, which checks TAG against the
# kubelet image: anything but the release breaks a node's config validation. This asks that
# Makefile what it would build with, called the way `installer` calls it.
.PHONY: check-talos-build
check-talos-build: checkout-talos ## Assert the Talos build gets its release as TAG and siderolabs' registry.
	@for want in TAG=$(TALOS_VERSION) REGISTRY=ghcr.io USERNAME=siderolabs; do \
	  var=$${want%%=*}; \
	  got=$$($(MAKE) -s --no-print-directory -C $(TALOS_DIR) --eval='print-%: ; @echo $$($$*)' print-$$var); \
	  [ "$$got" = "$${want#*=}" ] || { echo "the Talos build would get $$var=$$got, want $${want#*=}"; exit 1; }; \
	done
	@echo "the Talos build gets TAG=$(TALOS_VERSION), ghcr.io/siderolabs"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git jq curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable"; fail=1; }; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Checkouts

$(BUILD_DIR) $(OUT_DIR):
	@mkdir -p $@

.PHONY: checkout-pkgs
checkout-pkgs: | $(BUILD_DIR) ## Fetch siderolabs/pkgs at PKGS and overlay pkgs/.
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) rev-parse --verify --quiet '$(PKGS_COMMIT)^{commit}' >/dev/null \
	  || git -C $(PKGS_DIR) fetch --quiet --filter=blob:none --tags origin
	@full=$$(git -C $(PKGS_DIR) rev-parse --verify '$(PKGS_COMMIT)^{commit}'); \
	  git -C $(PKGS_DIR) checkout --quiet --force --detach "$$full"
	@git -C $(PKGS_DIR) clean --quiet -fd
	@cp -r pkgs/*/ $(PKGS_DIR)/

.PHONY: checkout-extensions
checkout-extensions: | $(BUILD_DIR) ## Fetch siderolabs/extensions at the Talos release and overlay extensions/.
	@if [ ! -d "$(EXTENSIONS_DIR)/.git" ]; then \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/extensions.git $(EXTENSIONS_DIR); \
	fi
	@git -C $(EXTENSIONS_DIR) fetch --quiet --filter=blob:none origin tag $(UPSTREAM_EXTENSIONS_REF)
	@git -C $(EXTENSIONS_DIR) checkout --quiet --force --detach $(UPSTREAM_EXTENSIONS_REF)
	@git -C $(EXTENSIONS_DIR) clean --quiet -fd
	@cp -r extensions/*/ $(EXTENSIONS_DIR)/

.PHONY: checkout-talos
checkout-talos: | $(BUILD_DIR) ## Fetch siderolabs/talos at the Talos release, for its kernel+initramfs recipe.
	@if [ ! -d "$(TALOS_DIR)/.git" ]; then \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/talos.git $(TALOS_DIR); \
	fi
	@git -C $(TALOS_DIR) fetch --quiet --filter=blob:none origin tag $(TALOS_VERSION)
	@git -C $(TALOS_DIR) checkout --quiet --force --detach $(TALOS_VERSION)

##@ Build (one arch)

.PHONY: nftables-pkg
nftables-pkg: checkout-pkgs ## Build the static nft and push it to REGISTRY.
	@echo "==> building $(NFTABLES_PKG_IMAGE)"
	@$(MAKE) -C $(PKGS_DIR) docker-nftables-pkg PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(NFTABLES_PKG_IMAGE) --push=true $(NFTABLES_PKG_ARGS)"

extension-%: checkout-extensions ## Build and push one extension: extension-amneziawg, -awg, -router, -nftables.
	@echo "==> building $(REGISTRY)/$*:$(TAG)-$(TARGET_ARCH) ($(VERSION_$*))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-$* PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(REGISTRY)/$*:$(TAG)-$(TARGET_ARCH) --push=true $(EXTENSION_ARGS) --build-arg=VERSION=$(VERSION_$*)"

extension-nftables: nftables-pkg

.PHONY: extensions
extensions: $(addprefix extension-,$(EXTENSIONS)) ## Build and push all four extensions.

# local-kernel/local-initramfs rather than the bare kernel/initramfs targets, which do not forward
# TARGET_ARGS. --network=host only matters for a build of a foreign arch: talos' own Dockerfile
# steps hang on `go mod download` under QEMU behind docker's bridge network.
.PHONY: installer
installer: check-talos-build | $(OUT_DIR) ## Bake the installer from the kernel and the extensions pushed under TAG.
	@echo "==> exporting $(BASE_INSTALLER) to an OCI layout"
	@docker pull -q --platform linux/$(TARGET_ARCH) $(BASE_INSTALLER) >/dev/null
	@rm -rf $(BASE_OCI_DIR); mkdir -p $(BASE_OCI_DIR)
	@printf 'FROM %s\n' $(BASE_INSTALLER) | docker buildx build --platform=linux/$(TARGET_ARCH) \
	  --output=type=oci,dest=$(BASE_OCI_DIR)/image.tar -
	@tar -xf $(BASE_OCI_DIR)/image.tar -C $(BASE_OCI_DIR) && rm -f $(BASE_OCI_DIR)/image.tar
	@jq '.manifests[0].platform = {architecture:"$(TARGET_ARCH)", os:"linux"}' $(BASE_OCI_DIR)/index.json \
	  > $(BASE_OCI_DIR)/index.json.tmp && mv $(BASE_OCI_DIR)/index.json.tmp $(BASE_OCI_DIR)/index.json
	@echo "==> extracting kernel and initramfs from $(KERNEL_IMAGE)"
	@mkdir -p $(CUSTOM_KERNEL_DIR)
	@$(MAKE) -C $(TALOS_DIR) local-kernel local-initramfs \
	  PKG_KERNEL=$(KERNEL_IMAGE) PLATFORM=linux/$(TARGET_ARCH) DEST=$(CURDIR)/$(CUSTOM_KERNEL_DIR) \
	  TARGET_ARGS="--network=host"
	@{ \
	  echo "arch: $(TARGET_ARCH)"; \
	  echo "platform: metal"; \
	  echo "secureboot: false"; \
	  echo "version: $(TALOS_VERSION)"; \
	  echo "input:"; \
	  echo "  kernel:"; \
	  echo "    path: /usr/install/$(TARGET_ARCH)/vmlinuz"; \
	  echo "  initramfs:"; \
	  echo "    path: /usr/install/$(TARGET_ARCH)/initramfs.xz"; \
	  echo "  baseInstaller:"; \
	  echo "    imageRef: $(INSTALLER_IMAGE)"; \
	  echo "    ociPath: /out/base-oci"; \
	  echo "  systemExtensions:"; \
	  for e in $(EXTENSION_IMAGES); do echo "    - imageRef: $$e"; done; \
	  echo "output:"; \
	  echo "  kind: installer"; \
	  echo "  outFormat: raw"; \
	} > $(OUT_DIR)/profile.yaml
	@echo "==> baking $(INSTALLER_IMAGE)"
	# No :z on this bind mount: on a host without SELinux the imager then fails with "error opening
	# OCI layout: stat /out/base-oci/index.json: no such file or directory".
	@docker run --rm -i --privileged --network host \
	  -v $(CURDIR)/$(OUT_DIR):/out \
	  -v $(CURDIR)/$(CUSTOM_KERNEL_DIR)/vmlinuz-$(TARGET_ARCH):/usr/install/$(TARGET_ARCH)/vmlinuz:ro \
	  -v $(CURDIR)/$(CUSTOM_KERNEL_DIR)/initramfs-$(TARGET_ARCH).xz:/usr/install/$(TARGET_ARCH)/initramfs.xz:ro \
	  -v /dev:/dev $(IMAGER) - --insecure \
	  < $(OUT_DIR)/profile.yaml
	@docker load -q -i $(OUT_DIR)/installer-$(TARGET_ARCH).tar >/dev/null
	@docker image inspect $(INSTALLER_IMAGE) --format 'built $(INSTALLER_IMAGE) arch={{.Architecture}} size={{.Size}}'

.PHONY: push
push: ## Push this arch's installer to REGISTRY.
	@docker push -q $(INSTALLER_IMAGE)

##@ Publish

# The imager pulls the extensions from a container of its own, without the host's registry
# credentials, so CI builds against a registry local to the job and copies the results out.
.PHONY: publish
publish: ## Copy this arch's extensions and installer from REGISTRY to PUBLISH_REGISTRY.
	@[ -n "$(PUBLISH_REGISTRY)" ] || { echo "PUBLISH_REGISTRY not set"; exit 1; }
	@for name in $(EXTENSIONS) talos-installer; do \
	  src=$(REGISTRY)/$$name:$(TAG)-$(TARGET_ARCH); dst=$(PUBLISH_REGISTRY)/$$name:$(TAG)-$(TARGET_ARCH); \
	  docker pull -q "$$src" >/dev/null; docker tag "$$src" "$$dst"; docker push -q "$$dst"; \
	done

.PHONY: manifest
manifest: ## Combine both arches' pushed installers into the multi-arch tag nodes pull.
	@docker buildx imagetools create -t $(MANIFEST_IMAGE) $(foreach a,$(ARCHS),$(REGISTRY)/talos-installer:$(TAG)-$(a))
	@echo "upgrade a node with: talosctl -n <node> upgrade --image $(MANIFEST_IMAGE)"

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute the LIBMNL_/LIBNFTNL_/NFTABLES_/MUSL_ hashes for the current versions.
	@for spec in "https://www.netfilter.org/projects/libmnl/files/libmnl-$(LIBMNL_VERSION).tar.bz2:LIBMNL" \
	             "https://netfilter.org/projects/libnftnl/files/libnftnl-$(LIBNFTNL_VERSION).tar.xz:LIBNFTNL" \
	             "https://netfilter.org/projects/nftables/files/nftables-$(NFTABLES_VERSION).tar.xz:NFTABLES" \
	             "https://www.musl-libc.org/releases/musl-$(MUSL_VERSION).tar.gz:MUSL"; do \
	  url=$${spec%:*}; var=$${spec##*:}; tmp=$$(mktemp); \
	  curl -sSL --fail "$$url" -o "$$tmp"; \
	  echo "$${var}_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	  echo "$${var}_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	  rm -f "$$tmp"; \
	done

.PHONY: clean
clean: ## Drop this build's outputs, keep the checkouts.
	@rm -rf $(BUILD_DIR)/out-*

.PHONY: distclean
distclean: ## Drop everything, including the checkouts.
	@rm -rf $(BUILD_DIR)
