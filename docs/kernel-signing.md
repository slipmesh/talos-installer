# Getting a signed kernel into the final installer

This repo's half of the mechanism described in `../talos-kernel/docs/kernel-signing.md`
(read that first for why the module needs to be signed the way it is at all) - how a
kernel package built there actually ends up inside a bootable installer image, without
ever needing a custom-built `imager` tool.

## Why not build a custom imager image

The official docs' example (`make kernel initramfs imager PKG_KERNEL=...`, run from a
`siderolabs/talos` checkout) reads like you need a whole custom `imager` container image.
Two things make a lighter approach both correct and preferable:

1. `siderolabs/talos`'s own `imager` container has `/usr/install/<arch>/{vmlinuz,
   initramfs.xz}` baked directly into its filesystem at build time (`Dockerfile`, the
   `installer-build`/`imager` stages: `COPY --from=pkg-kernel-amd64 /boot/vmlinuz
   /usr/install/amd64/vmlinuz`, and similarly for the initramfs). `imager`'s own profile
   format reads `input.kernel.path`/`input.initramfs.path` as plain paths *on its own
   container filesystem* (`pkg/imager/profile/input.go`'s `FileAsset{Path string}` —
   nothing baseInstaller-relative about it), independent of whatever `baseInstaller`
   image it's asked to otherwise mutate.
2. Docker lets us override files inside a container at `docker run` time with a bind
   mount — no rebuild required.

So: `make kernel initramfs PKG_KERNEL=<KERNEL_IMAGE> DEST=...` in a `siderolabs/talos`
checkout (a *local* output, `local-kernel`/`local-initramfs` — no `imager` container gets
built at all) produces `vmlinuz-<arch>` and `initramfs-<arch>.xz`, both built against
whatever kernel package `KERNEL_IMAGE` points at — meaning `initramfs.xz`'s own squashfs
content (including anything like `virtio_pci.ko`) comes from the *same* coordinated,
coherently-signed build as the kernel's own modules, not a mismatched stock one (see
`../talos-kernel/docs/kernel-signing.md`, "What doesn't work: swapping only the kernel"
for why that mismatch matters). `make installer`'s recipe then runs the **stock**
`ghcr.io/siderolabs/imager:$(TALOS_VERSION)` — completely unmodified — bind-mounting
those two extracted files over their conventional paths:

```sh
docker run --rm -i --privileged --network host \
  -v $(OUT_DIR):/out:z \
  -v $(CUSTOM_KERNEL_DIR)/vmlinuz-$(TARGET_ARCH):/usr/install/$(TARGET_ARCH)/vmlinuz:ro \
  -v $(CUSTOM_KERNEL_DIR)/initramfs-$(TARGET_ARCH).xz:/usr/install/$(TARGET_ARCH)/initramfs.xz:ro \
  -v /dev:/dev $(IMAGER) - --insecure < profile.yaml
```

Everything else about the installer — rootfs, sd-boot/sd-stub, system extensions via
`systemExtensions` — is untouched, exactly as stock imager assembles it. Only the two
files a mismatched signing key could ever actually affect are swapped in.

This also means no separate `imager` image gets built, tagged, or published — one fewer
artifact to track.

## The `--network=host` fix

`local-kernel`/`local-initramfs` (not the bare `kernel`/`initramfs` shortcuts, which
don't forward `TARGET_ARGS`) run with `TARGET_ARGS="--network=host"`. Without it,
`siderolabs/talos`'s own Dockerfile `RUN` steps for a `TARGET_ARCH` different from the
build host's own architecture (`go mod download`, in particular) hang indefinitely under
plain Docker bridge networking when run through QEMU emulation: a plain
`docker run --platform=linux/amd64 ... curl -4` to any address times out under the default
bridge network on an arm64 host, and works instantly under `--network=host`.
Nothing wrong with the module fetch itself — `--network=host` sidesteps whatever's broken
in the emulated-container-to-bridge-NAT path entirely.

## Verifying it worked

```sh
talosctl -n <node> read /proc/cmdline                      # module.sig_enforce=1
talosctl -n <node> read /sys/module/module/parameters/sig_enforce   # Y
talosctl -n <node> dmesg | grep -iE "unsigned module|module verification failed"   # nothing
talosctl -n <node> get extensions                           # every extension you passed
```
