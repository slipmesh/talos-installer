# The `router` extension

Pure userspace, no kernel module. Three binaries, in `/usr/local/lib/containers/router/`:

- `router`, the `ext-router` extension service, built in
  [talos-extensions](https://github.com/slipmesh/talos-extensions). It renders BIRD's config
  (OSPFv3 over mesh links, full-mesh iBGP over loopbacks, bypass routes) and reloads it over BIRD's
  control socket.
- `bird`, a fully static BIRD built here from the unmodified upstream tag `BIRD_REV`, which
  `router` spawns. It is built against glibc on Ubuntu: BIRD 3's own test suite dies with SIGILL
  in a static musl build. No BIRD client ships: the control socket, `/run/bird.ctl` in the
  service's mount namespace, is only reachable from a privileged pod in the host PID namespace,
  as `/proc/<bird pid>/root/run/bird.ctl`, and such a pod can bring its own client.
- `bird_exporter`, spawned by `router`, reading the same socket.

Like `ext-awg`, it works before the node joins a cluster: everything comes from static config,
nothing is discovered from Kubernetes.

## Licenses

The extension distributes BIRD (GPL-2.0), glibc statically linked into it (LGPL-2.1),
bird_exporter (MIT) and the Go modules linked into bird_exporter, each under its own license.
Their texts ship in `/usr/local/share/licenses/router/`, with a `*.SOURCE` file naming BIRD's tag
and commit and glibc's Ubuntu source package. All are used without modification.

## Config

`router.yaml` holds the facts; talos-extensions' README, `router` section, documents every field.

```yaml
node:
  loopback_addresses: ["192.0.2.1/32", "2001:db8::1/128"]   # exactly one IPv4 and one IPv6
bgp_as: 64512
bgp_peers:                          # every other mesh node; a single bare IPv6 address each
  - name: node-b
    address: 2001:db8::2
ospf_interfaces: ["mesh-*"]         # names, shell globs or CIDRs, as BIRD's `interface` takes them
learn: ["198.51.100.0/24"]           # kernel routes inside these are re-announced over iBGP
announce:
  - net: "10.96.0.0/12"
    label: "k8s-services"
bypass:                             # optional, resolved live
  refresh_interval_secs: 86400
  include:
    - kind: asn
      label: "some vendor"
      asns: ["AS15169"]
  exclude:
    - kind: literal
      prefixes: [{net: "10.0.0.0/8"}]
```

Nothing excludes this node's or a peer's own public endpoint from `bypass` automatically: if
`bypass.include` could cover one, list it in `bypass.exclude`.

BIRD's config is a second file, `router.conf.j2`, a minijinja template of `router.yaml` that
`ext-router` renders at startup and on every bypass refresh. It ships none of its own and exits
without one; talos-extensions' `router/templates/router.conf.j2` is the reference template.

## Machine config

The `ExtensionServiceConfig` must be named `router`, with its files mounted at exactly
`/etc/talos-extensions/router.yaml` and `/etc/talos-extensions/router.conf.j2`:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: router
configFiles:
  - mountPath: /etc/talos-extensions/router.yaml
    content: |
      node:
        loopback_addresses: ["192.0.2.1/32", "2001:db8::1/128"]
      # ...
  - mountPath: /etc/talos-extensions/router.conf.j2
    content: |
      router id {{ loopback }};
      # ... the rest of the reference template ...
```

`talosctl apply-config` with a changed document restarts the whole service, `router` and its
`bird` both.

## Verifying on a node

- `talosctl -n <node> get extensions`: `router`.
- `talosctl -n <node> service ext-router`: `Running` once converged; `restart: always`, so a
  failed start, `bird` exiting included, retries every 5 s.
- `talosctl -n <node> logs ext-router`: `bird` logs to `router`'s stderr, so both daemons are
  there, and in `dmesg` through `logToConsole: true`.
