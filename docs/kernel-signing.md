# Getting a signed kernel and module into the installer

Nodes boot with `module.sig_enforce=1`, so the amneziawg module has to be signed with the key of
the kernel it loads into. [talos-kernel](https://github.com/slipmesh/talos-kernel) builds the
kernel and the module together for that reason; its
[docs/kernel-signing.md](https://github.com/slipmesh/talos-kernel/blob/main/docs/kernel-signing.md)
explains the signing itself. This repository only carries the two results into an installer
without touching them.

## The module: an OCI layer, not a rebuild

`extensions/amneziawg/pkg.yaml` takes `amneziawg-pkg` from talos-kernel as an image dependency
and copies its `.ko` files into the extension, the way upstream's `storage/zfs` takes `zfs-pkg`.
Nothing is recompiled, so the signature stays as talos-kernel made it. The package's test fails
the build if any module lacks the `~Module signature appended~` marker.

## The kernel: the stock imager with two files swapped

`make installer` gets a matching `vmlinuz` and `initramfs.xz` from a siderolabs/talos checkout,
with `make local-kernel local-initramfs PKG_KERNEL=<talos-kernel's kernel image>`. The initramfs
then holds modules from the same signed build as the kernel. A stock initramfs would carry
modules signed with siderolabs' key, `virtio_pci.ko` among them, which this kernel refuses.

The stock `ghcr.io/siderolabs/imager` then bakes the installer, unmodified. It reads
`input.kernel.path` and `input.initramfs.path` from its own filesystem, so `make installer`
bind-mounts the two files over `/usr/install/<arch>/`. The rootfs, sd-boot, sd-stub and system
extensions come out exactly as stock imager assembles them, and no custom imager image is built
or published.

## Verifying on a node

```sh
talosctl -n <node> read /proc/cmdline                                # module.sig_enforce=1
talosctl -n <node> read /sys/module/module/parameters/sig_enforce    # Y
talosctl -n <node> dmesg | grep -iE "unsigned module|module verification failed"   # nothing
talosctl -n <node> get extensions                                    # amneziawg, awg, router, nftables
```
