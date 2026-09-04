# talos-installer

Assembles a bootable Talos installer image from a signed kernel and any number of system
extensions — the final "glue" step of a split five-repo pipeline. Deliberately generic:
this repo has no source-level knowledge of `awg`/`router`/anything else, only OCI image
references passed in on the command line. Adding a fifth extension later needs zero
changes here.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.

## This is one of five repos

- [talos-kernel](https://github.com/slipmesh/talos-kernel) —
  signed kernel + `amneziawg-pkg`
- [talos-awg-extension](https://github.com/slipmesh/talos-awg-extension) —
  amneziawg system extension (pulls `amneziawg-pkg`)
- [talos-router-extension](https://github.com/slipmesh/talos-router-extension) —
  router system extension (no kernel dependency)
- [talos-nftables-extension](https://github.com/slipmesh/talos-nftables-extension) —
  nftables system extension (no kernel dependency)
- [talos-installer](https://github.com/slipmesh/talos-installer) —
  assembles a kernel + N extensions into an installer — **this repo**

This repo consumes the other four's *published* images only, by tag - it never checks
out or builds their source. See `docs/kernel-signing.md` for how a signed kernel actually
ends up inside the final installer without needing a custom `imager` image.

## Usage

`KERNEL_IMAGE` and `EXTENSIONS` (space-separated image refs) are required, no defaults -
a silently-wrong kernel or an accidentally-dropped extension is worse than a loud error
demanding both every time. `EXTENSIONS` entries are **arch-less base refs** - `installer`
appends `-$(TARGET_ARCH)` itself (every extension repo publishes an arch-suffixed tag,
never a multi-arch manifest, so the same `EXTENSIONS` string has to resolve correctly for
both arches `release`'s loop builds - see the Makefile's own comment):

```sh
make print-config TARGET_ARCH=amd64 \
  KERNEL_IMAGE=ghcr.io/slipmesh/kernel:v0.1.1-talos1.13.9 \
  EXTENSIONS="ghcr.io/slipmesh/talos-awg-extension:v0.1.2-talos1.13.9 ghcr.io/slipmesh/talos-router-extension:v0.1.1-bird2.18"

make preflight   # docker/buildx/git/jq present, KERNEL_IMAGE/EXTENSIONS set

make installer TARGET_ARCH=amd64 \
  KERNEL_IMAGE=ghcr.io/slipmesh/kernel:v0.1.1-talos1.13.9 \
  EXTENSIONS="ghcr.io/slipmesh/talos-awg-extension:v0.1.2-talos1.13.9 ghcr.io/slipmesh/talos-router-extension:v0.1.1-bird2.18"

make push TARGET_ARCH=amd64
```

Get the actual current tags from each extension repo's own `make extension` output (it
prints the published ref) and from `talos-kernel`'s `make kernel` output.

`installer`/`push` work on one `TARGET_ARCH` at a time and tag/publish
`installer-<talos>-<build-slug>-<arch>`. `<build-slug>` is a short hash of
`KERNEL_IMAGE`+`EXTENSIONS` (not a version you pick) — it exists purely so a rebuild with
different inputs always gets a genuinely new tag; re-pushing under a tag that's already
been used has been observed to *not* reliably reach a node on `talosctl upgrade`
(confirmed directly, at both the extension and the installer level). The tag nodes actually pull
is the arch-less `installer-<talos>-<build-slug>`, a multi-arch manifest:

```sh
make release TARGET_ARCH=amd64 \
  KERNEL_IMAGE=... EXTENSIONS="..."   # builds+pushes every ARCHS entry, then the multi-arch tag
```

Then, per node (check `make print-config` for the exact tag - or just read what
`make installer`/`release` printed):

```sh
talosctl -n <node> upgrade --image ghcr.io/slipmesh/talos-installer:installer-<talos>-<build-slug>
```

## How it works

`checkout-talos` clones `siderolabs/talos` at the pinned `TALOS_VERSION` tag (used only
for its own `make local-kernel local-initramfs` recipe, not modified). `installer`:

1. Exports the stock `ghcr.io/siderolabs/installer-base:$(TALOS_VERSION)` to a local OCI
   layout — the rootfs and sd-boot/sd-stub come from here. Kernel and initramfs are
   replaced in step 2, extensions added in step 3; neither comes from this image.
2. Extracts a coherent `vmlinuz`+`initramfs.xz` pair from `KERNEL_IMAGE` via
   `siderolabs/talos`'s own `local-kernel`/`local-initramfs` targets.
3. Runs the **stock** `ghcr.io/siderolabs/imager` — unmodified — bind-mounting those two
   files over its own baked-in paths, with every `EXTENSIONS` entry listed in the
   profile's `systemExtensions`.

See `docs/kernel-signing.md` for the full detail and why this is both simpler and safer
than building a custom `imager` image.

```text
versions.env    TALOS_VERSION (must match what KERNEL_IMAGE/every extension were built
                against), IMAGE (registry namespace for the published installer tag)
docs/
  kernel-signing.md   how a signed kernel gets into the installer without a custom imager
build/          (gitignored) the talos checkout, plus imager output
```

## Verifying a build

```sh
docker buildx imagetools inspect <installer image>
```

Full node-level verification after `talosctl upgrade`:

```sh
talosctl -n <node> read /proc/cmdline                       # module.sig_enforce=1
talosctl -n <node> dmesg | grep -iE "unsigned module|module verification failed"   # nothing
talosctl -n <node> get extensions                            # every extension you passed
```

## Bumping

Bump `TALOS_VERSION` here to match whatever `talos-kernel` and every extension repo
were built against, then re-run `installer`/`release` with their current published tags.
This repo has no other pins of its own.
