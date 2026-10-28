# talos-installer

Builds the slipmesh Talos system extensions and bakes them, with a signed kernel, into a Talos
installer image that nodes upgrade to:

| extension | carries | docs |
| --- | --- | --- |
| `amneziawg` | the AmneziaWG kernel module, signed in talos-kernel | [awg.md](docs/awg.md) |
| `awg` | `ext-awg`, which brings up the AmneziaWG interfaces | [awg.md](docs/awg.md) |
| `router` | `ext-router` with a static BIRD and bird_exporter | [router.md](docs/router.md) |
| `nftables` | the nftables ruleset service with a static `nft` | [nftables.md](docs/nftables.md) |

The inputs come by pin from two other repositories, built there and never rebuilt here:

- [talos-kernel](https://github.com/slipmesh/talos-kernel): the signed kernel and the
  `amneziawg-pkg` module package, named by `KERNEL_RELEASE`. See
  [kernel-signing.md](docs/kernel-signing.md) for how both reach the installer untouched.
- [talos-extensions](https://github.com/slipmesh/talos-extensions): the `awg`, `router` and
  `nftables` daemons with their extension-service specs, in the image `DAEMONS_IMAGE` pins by
  digest.

The extensions are built with siderolabs/extensions' own bldr pipeline, at the tag of the Talos
release `KERNEL_RELEASE` names; the installer is baked by the stock siderolabs imager of that
release.

## Layout

```text
versions.env        every pin: kernel release, daemons image, pkgs, nftables, BIRD, registry
extensions/<name>/  overlaid onto the siderolabs/extensions checkout; router-bird and
                    router-bird-exporter are build stages of router
pkgs/nftables-pkg/  overlaid onto the siderolabs/pkgs checkout, builds the static nft
docs/               per extension, and how the signed kernel gets in
build/              (gitignored) the checkouts and the imager output
```

## Building

Needs Docker with `docker buildx`. Builds work on one `TARGET_ARCH` at a time; on a host of the
other arch, buildx emulates it under QEMU.

```sh
make print-config TARGET_ARCH=amd64   # resolved pins and image names
make check-pins                       # pins agree with KERNEL_RELEASE and its Talos release
make extensions TARGET_ARCH=amd64     # build and push the four extensions
make installer push TARGET_ARCH=amd64 # bake and push this arch's installer
make manifest                         # combine both arches into the tag nodes pull
```

Images go to `REGISTRY` (default `ghcr.io/slipmesh`) and are tagged `TAG`, by default
`sha-<HEAD commit>`, per arch as `<TAG>-<arch>`. The imager pulls the extensions without the
host's registry credentials, so they must be pullable anonymously from `REGISTRY`. A local
registry works:

```sh
docker run -d -p 5000:5000 registry:3
make extensions installer push TARGET_ARCH=amd64 REGISTRY=localhost:5000
```

`make publish PUBLISH_REGISTRY=...` copies one arch's extensions and installer from `REGISTRY` to
another registry under the same tags.

## CI and releases

Every push and pull request builds the four extensions and the installer for both arches, each on
a runner of its own arch, against a registry local to the job. A push to `main` or a `release-*`
branch then publishes them to ghcr.io as `sha-<commit>` and merges the installer into a
multi-arch `ghcr.io/slipmesh/talos-installer:sha-<commit>`.

A release builds nothing. The Release PR workflow (Actions, then Release PR) opens
`chore: release vX.Y.Z` with `CHANGELOG.md` regenerated; merging it tags the commit, retags its
`sha-<commit>` installer as the release, and creates the GitHub Release. Then, per node:

```sh
talosctl -n <node> upgrade --image ghcr.io/slipmesh/talos-installer:<release tag, + as ->
```

## Bumping

- **Talos patch:** release talos-kernel for it, then set `KERNEL_RELEASE` to that release. `AWG_REF`
  and `PKGS` follow: `make check-pins` names the values it expects.
- **Daemons:** set `DAEMONS_IMAGE` to a newer `ghcr.io/slipmesh/talos-extensions` tag with its
  digest, from `docker buildx imagetools inspect <image>:<tag>`.
- **nftables, libnftnl, libmnl, musl:** set the version, run `make hashes`, paste the values back.
- **BIRD:** set `BIRD_REV` and `BIRD_COMMIT`, the commit that tag names upstream.

## Verifying a build

Every extension's bldr test runs siderolabs' `extensions-validator` on it, and the amneziawg,
nftables-pkg and router-bird stages test their own output: module signatures, a static `nft`
with its license texts, BIRD's own `make check`. A build that completes has passed them.

On a node, after `talosctl upgrade`, see the checks in
[kernel-signing.md](docs/kernel-signing.md#verifying-on-a-node) and each extension's doc.

## License

This repository's own code is MIT or Apache-2.0. The images it builds also distribute the
third-party software listed in each extension's doc, with its license texts inside the image.
