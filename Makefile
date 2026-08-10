# Assembles a bootable Talos installer image from a signed kernel (../talos-kernel) and
# any number of system extensions (../talos-awg-extension, ../talos-router-extension, or
# anything else that publishes a Talos extension image) - the final "glue" step of a
# split five-repo pipeline. See README, "This is one of five repos".
#
# Deliberately generic: this repo has no source-level knowledge of awg/router/anything
# else, only OCI image references passed in on the command line. Adding a fifth extension
# later needs zero changes here.
#
# Needs Docker + `docker buildx`.
#
# build/ is disposable: `make distclean` drops it; the talos checkout is re-fetched as
# needed.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out release push-manifest distclean help checkout-talos,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64, or run `make release` to build both)
  endif
endif

# Required inputs for `installer`/`release` - no defaults on purpose, a silently-wrong
# kernel or an accidentally-dropped extension is worse than a loud error demanding both
# be named explicitly every time. See README, "Usage".
#   make installer TARGET_ARCH=amd64 \
#     KERNEL_IMAGE=docker.io/ffaxl/kernel:v1.13.8-awg-ce16310 \
#     EXTENSIONS="docker.io/ffaxl/talos:extension-v1.13.8-awg-1422b3d-amd64 docker.io/ffaxl/talos:extension-v1.13.8-router-abc1234-amd64"
KERNEL_IMAGE ?=
EXTENSIONS   ?=

BUILD_DIR := build
TALOS_DIR := $(BUILD_DIR)/talos
OUT_DIR   := $(BUILD_DIR)/out-$(TARGET_ARCH)

# A build-specific slug folded into the tag so re-pushing under a tag that's already been
# used doesn't silently fail to reach a node (confirmed directly in ../talos-awg-extension
# - see that repo's AGENTS.md). Derived from KERNEL_IMAGE + every EXTENSIONS entry so it
# changes whenever any input does, without needing this repo to know their internal pin
# schemes.
BUILD_SLUG      := $(shell echo -n "$(KERNEL_IMAGE) $(EXTENSIONS)" | sha256sum | cut -c1-12)
INSTALLER_IMAGE := $(IMAGE):installer-$(TALOS_VERSION)-$(BUILD_SLUG)-$(TARGET_ARCH)
MANIFEST_IMAGE  := $(IMAGE):installer-$(TALOS_VERSION)-$(BUILD_SLUG)
ARCHS           := amd64 arm64

# The imager *tool* stays the stock siderolabs one - unmodified, never rebuilt. Getting a
# coherently-signed kernel+initramfs into its output is a bind-mount at run time, not a
# rebuild of the tool itself. See docs/kernel-signing.md.
IMAGER            := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
BASE_OCI_DIR      := $(OUT_DIR)/base-oci
CUSTOM_KERNEL_DIR := $(OUT_DIR)/custom-kernel

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved arch and image names (KERNEL_IMAGE/EXTENSIONS as given).
	@echo "talos            : $(TALOS_VERSION)"
	@echo "target arch      : $(TARGET_ARCH)"
	@echo "kernel image     : $(KERNEL_IMAGE)"
	@echo "extensions       : $(EXTENSIONS)"
	@echo "installer image  : $(INSTALLER_IMAGE)"
	@echo "manifest image   : $(MANIFEST_IMAGE)"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git jq; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	[ -n "$(KERNEL_IMAGE)" ] || { echo "MISSING: KERNEL_IMAGE not set"; fail=1; }; \
	[ -n "$(EXTENSIONS)" ] || { echo "MISSING: EXTENSIONS not set (space-separated image refs)"; fail=1; }; \
	echo "host $$(uname -m)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR) $(OUT_DIR):
	@mkdir -p $@

.PHONY: checkout-talos
checkout-talos: | $(BUILD_DIR) ## Fetch siderolabs/talos at $(TALOS_VERSION) - used only to extract a kernel+initramfs pair built against KERNEL_IMAGE.
	@if [ ! -d "$(TALOS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/talos"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/talos.git $(TALOS_DIR); \
	fi
	@git -C $(TALOS_DIR) fetch --quiet --filter=blob:none origin $(TALOS_VERSION) 2>/dev/null || git -C $(TALOS_DIR) fetch --quiet origin
	@git -C $(TALOS_DIR) checkout --quiet --force --detach $(TALOS_VERSION)

# Exports a registry image to a plain OCI-layout directory and stamps a platform onto its
# index - via `docker buildx build --output=type=oci`, the one docker-native way to get a
# real OCI layout (index.json + blobs/) onto disk. $(1) = source image, $(2) = dest dir.
define export-to-oci
	rm -rf $(2); mkdir -p $(2); \
	printf 'FROM %s\n' $(1) | docker buildx build --platform=linux/$(TARGET_ARCH) \
	  --output=type=oci,dest=$(2)/image.tar -; \
	tar -xf $(2)/image.tar -C $(2); rm -f $(2)/image.tar; \
	tmp=$$(mktemp); \
	jq '.manifests[0].platform = {architecture:"$(TARGET_ARCH)", os:"linux"}' \
	  $(2)/index.json >"$$tmp" && mv "$$tmp" $(2)/index.json
endef

# $(file ...) writes are expanded when make builds a recipe's command text, which happens
# before ANY of the recipe's own lines actually run (confirmed directly, see
# ../talos-awg-extension/AGENTS.md) - so profile.yaml is built as one shell block instead,
# not a $(file) write, since the systemExtensions section needs a runtime loop over
# EXTENSIONS (a make-level $(foreach) here collapses newlines to spaces before the text
# ever reaches a file - also confirmed directly).
#
# local-kernel/local-initramfs (not the bare kernel/initramfs shortcuts, which don't
# forward TARGET_ARGS) with --network=host: siderolabs/talos's own Dockerfile RUN steps
# for TARGET_ARCH != host arch (go mod download, in particular) hang indefinitely under
# plain docker-bridge networking when run through QEMU emulation - confirmed directly on a
# real host. Not something wrong with the module fetch itself; --network=host sidesteps
# whatever's broken in the emulated-container-to-bridge-NAT path entirely.
.PHONY: installer
installer: checkout-talos | $(OUT_DIR) ## Bake an installer image from KERNEL_IMAGE + EXTENSIONS (both required).
	@[ -n "$(KERNEL_IMAGE)" ] || { echo "KERNEL_IMAGE not set"; exit 1; }
	@[ -n "$(EXTENSIONS)" ] || { echo "EXTENSIONS not set"; exit 1; }
	@echo "==> exporting base installer to OCI layout"
	@docker pull -q --platform linux/$(TARGET_ARCH) ghcr.io/siderolabs/installer:$(TALOS_VERSION) >/dev/null
	@$(call export-to-oci,ghcr.io/siderolabs/installer:$(TALOS_VERSION),$(BASE_OCI_DIR))
	@echo "==> extracting kernel+initramfs from $(KERNEL_IMAGE)"
	@mkdir -p $(CUSTOM_KERNEL_DIR)
	@$(MAKE) -C $(TALOS_DIR) local-kernel local-initramfs \
	  PKG_KERNEL=$(KERNEL_IMAGE) PLATFORM=linux/$(TARGET_ARCH) DEST=$(PWD)/$(CUSTOM_KERNEL_DIR) \
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
	  for e in $(EXTENSIONS); do echo "    - imageRef: $$e"; done; \
	  echo "output:"; \
	  echo "  kind: installer"; \
	  echo "  outFormat: raw"; \
	} > $(OUT_DIR)/profile.yaml
	@echo "==> baking installer for $(TALOS_VERSION)/$(TARGET_ARCH)"
	@docker run --rm -i --privileged --network host \
	  -v $(PWD)/$(OUT_DIR):/out:z \
	  -v $(PWD)/$(CUSTOM_KERNEL_DIR)/vmlinuz-$(TARGET_ARCH):/usr/install/$(TARGET_ARCH)/vmlinuz:ro \
	  -v $(PWD)/$(CUSTOM_KERNEL_DIR)/initramfs-$(TARGET_ARCH).xz:/usr/install/$(TARGET_ARCH)/initramfs.xz:ro \
	  -v /dev:/dev $(IMAGER) - --insecure \
	  < $(OUT_DIR)/profile.yaml
	@docker load -q -i $(OUT_DIR)/installer-$(TARGET_ARCH).tar >/dev/null
	@docker image inspect $(INSTALLER_IMAGE) --format 'built $(INSTALLER_IMAGE) arch={{.Architecture}} size={{.Size}}'
	@echo -n "$(INSTALLER_IMAGE)" > $(OUT_DIR)/installer-image.txt
	@echo -n "$(MANIFEST_IMAGE)" > $(OUT_DIR)/manifest-image.txt

# push/push-manifest read the tag back from what `installer` wrote instead of
# recomputing BUILD_SLUG from KERNEL_IMAGE/EXTENSIONS - those aren't required again here
# on purpose. Recomputing was tried first and is a real footgun: BUILD_SLUG silently
# resolves to a *different* tag than the one actually built the moment KERNEL_IMAGE/
# EXTENSIONS aren't passed identically to every target in the same invocation (confirmed
# directly - `make installer KERNEL_IMAGE=... EXTENSIONS=...` followed by a bare `make
# push` tried to push a tag that was never built).
.PHONY: push
push: ## Push this arch's installer (intermediate - see push-manifest for what nodes pull).
	@[ -f $(OUT_DIR)/installer-image.txt ] || { echo "no build/out-$(TARGET_ARCH)/installer-image.txt - run 'make installer' first (same invocation or a prior one)"; exit 1; }
	@img=$$(cat $(OUT_DIR)/installer-image.txt); \
	docker push "$$img"; \
	echo "pushed $$img - run push-manifest once every arch you need is pushed"

.PHONY: push-manifest
push-manifest: ## Combine the per-arch installers already in the registry into one multi-arch tag.
	@manifest=""; \
	imgs=""; \
	for a in $(ARCHS); do \
	  f=$(BUILD_DIR)/out-$$a/installer-image.txt; \
	  [ -f "$$f" ] || { echo "missing $$f - run: make installer push TARGET_ARCH=$$a KERNEL_IMAGE=... EXTENSIONS=..."; exit 1; }; \
	  img=$$(cat "$$f"); \
	  docker image inspect "$$img" >/dev/null 2>&1 || docker pull -q "$$img" >/dev/null; \
	  imgs="$$imgs $$img"; \
	  manifest=$$(cat $(BUILD_DIR)/out-$$a/manifest-image.txt); \
	done; \
	docker manifest rm "$$manifest" >/dev/null 2>&1 || true; \
	docker manifest create "$$manifest" $$imgs >/dev/null; \
	docker manifest push "$$manifest"; \
	echo; \
	echo "pushed multi-arch $$manifest ($(ARCHS))"; \
	echo "upgrade a node with:"; \
	echo "  talosctl -n <node> upgrade --image $$manifest"

.PHONY: release
release: ## Build+push every arch and publish the multi-arch tag - the one command for a release.
	@for a in $(ARCHS); do \
	  echo "==> $$a"; \
	  $(MAKE) --no-print-directory installer push TARGET_ARCH=$$a KERNEL_IMAGE="$(KERNEL_IMAGE)" EXTENSIONS="$(EXTENSIONS)"; \
	done
	@$(MAKE) --no-print-directory push-manifest

##@ Maintenance

.PHONY: clean
clean: ## Drop build outputs, keep the pinned checkout.
	@rm -rf $(OUT_DIR)

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
