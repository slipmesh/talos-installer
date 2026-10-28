# The `nftables` extension

Pure userspace, no kernel module. Two binaries, in `/usr/local/lib/containers/nftables/`:

- `nftables`, the extension service, built in
  [talos-extensions](https://github.com/slipmesh/talos-extensions); its README, `nftables`
  section, documents the config and the reference ruleset template. It renders the ruleset
  template `/etc/talos-extensions/nftables.conf.j2` with values only the running node knows, such
  as the interface carrying the default route, applies it, and keeps watching with `nft monitor`:
  a first iptables-nft bootstrap around kubelet and kube-proxy startup can remove its tables in a
  boot-time race, and it then reapplies them.
- `nft`, built statically here by `pkgs/nftables-pkg`.

## A static `nft`

siderolabs/pkgs ships nftables, but its `nft` links libmnl, libnftnl and libjansson dynamically,
and the extension stages no shared libraries. `pkgs/nftables-pkg` builds libmnl, libnftnl and
nftables from netfilter.org's release tarballs, all `--disable-shared --enable-static`, in a
siderolabs/pkgs checkout at `PKGS`:

- `nft` is linked with libtool's `-all-static`: plain `-static` makes libtool prefer static
  libtool libraries and still yields a dynamically linked `nft`. The package's test fails if the
  binary has a `PT_INTERP` header.
- `--without-cli` drops the interactive mode and its readline; the service only runs `nft -f -`.
- `--with-json=no` drops libjansson, `--with-mini-gmp=yes` the external GMP.

nft 1.1.3 and later write set-element userdata that kube-proxy's bundled nft below 1.0.6.1 crashes
on (kubernetes/kubernetes#136786). Kubernetes 1.36.3 carries the fix (#140405); clusters on an
older Kubernetes need nft held below 1.1.3.

## Licenses

`nft` is static, so the extension distributes nftables and libnftnl (GPL-2.0-or-later), libmnl
(LGPL-2.1-or-later) and musl (MIT) inside it. Their license texts ship in
`/usr/local/share/licenses/nftables/`: `COPYING` from each netfilter.org tarball and `COPYRIGHT`
from the musl release tarball `MUSL_VERSION` pins. musl itself is linked from the tools image
`PKGS` selects, so the package's test fails when that image's musl is not `MUSL_VERSION`. All four
are used without modification; a `*.SOURCE` file beside each text names the release and where its
source comes from. The `nftables` service runs `nft` as a separate process and is not linked with
it.

## Machine config

The `ExtensionServiceConfig` must be named `nftables`, with the template mounted at exactly
`/etc/talos-extensions/nftables.conf.j2`:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: nftables
configFiles:
  - mountPath: /etc/talos-extensions/nftables.conf.j2
    content: |
      table inet slipmesh {
        # ...
      }
```

## Verifying on a node

- `talosctl -n <node> get extensions`: `nftables`.
- `talosctl -n <node> service ext-nftables` and `talosctl -n <node> logs ext-nftables`.
