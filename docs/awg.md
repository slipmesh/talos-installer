# AmneziaWG: the `amneziawg` and `awg` extensions

Two extensions work together:

- `amneziawg` carries the signed kernel module (see [kernel-signing.md](kernel-signing.md)). It
  only loads when machine config asks for it in `machine.kernel.modules`.
- `awg` carries the `ext-awg` extension service, which creates and configures the AmneziaWG
  interfaces: mesh links to other nodes, road-warrior clients, or both. Without it the module
  loads and no interface comes up.

The module is GPL-2.0; its license text ships beside it in
`/usr/local/share/licenses/amneziawg/COPYING`, and the package's test fails without it.

The daemon is built in [talos-extensions](https://github.com/slipmesh/talos-extensions), whose
README documents its full config schema and design. It reads its config from machine config, not
from Kubernetes, because a node in a multi-site mesh may only reach the API server through this
overlay.

## Config

Every `interfaces[]` entry has the same shape. Whether a peer is a mesh link or a road-warrior
client depends only on `allowed_ips`:

- **no `allowed_ips`**: full tunnel (`0.0.0.0/0`, `::/0`), no handshake polling, no kernel route.
  For node-to-node links, where a routing protocol over the tunnel provides reachability.
- **explicit `allowed_ips`**: exactly those CIDRs, handshake polled every second, a kernel route
  per CIDR while the handshake is fresher than `handshake_stale_secs` (default 180). For
  road-warrior clients: the route is the "connected" signal.

```yaml
interfaces:
  - name: mesh-a1b2c3d4            # any valid Linux ifname
    listen_port: 51820
    addresses: ["fe80::a1b2:c3d4/64"]
    private_key: "...this node's own, base64..."
    obfuscation: {jc: 4, jmin: 40, jmax: 70, h1: 1, h2: 2, h3: 3, h4: 4}   # every field optional
    peers:
      - public_key: "...base64..."
        endpoint: "203.0.113.7:51820"  # omit for a peer behind NAT
  - name: rw-eu
    listen_port: 51900
    addresses: ["198.51.100.1/24", "2001:db8:99::1/64"]
    private_key: "...the same on every node sharing this identity..."
    peers:
      - public_key: "...base64..."
        name: client-one               # display only: the peer_name metric label
        allowed_ips: ["198.51.100.5/32"]
metrics:                           # optional; without it nothing listens
  listen: "192.0.2.4:9586"
```

`ext-awg` never generates or stores a private key; whoever renders machine config supplies every
key.

Bind `metrics.listen` to the node's own mesh loopback address. That address exists only inside the
overlay, and kubelet reports it as the node's `InternalIP`, so Prometheus reaches it through node
discovery. Another extension brings the address up, so the socket is bound with `IP_FREEBIND` and
starts answering once it appears. Series are `slipmesh_awg_*`, labelled `interface`, `kind`, `peer`
and `peer_name`; private keys and endpoints never appear.

## Machine config

The `ExtensionServiceConfig` must be named `awg`, and its file must be mounted at exactly
`/etc/talos-extensions/awg.yaml`, the path `ext-awg` reads:

```yaml
machine:
  kernel:
    modules:
      - name: amneziawg
  sysctls:
    # Keeps a static address, an interface's IPv6 link-local in particular, across a down/up.
    # ext-awg creates its interfaces after boot and cannot write /proc/sys itself, so the
    # default template is set instead; the kernel copies it into every new interface.
    net.ipv6.conf.default.keep_addr_on_down: "1"
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: awg
configFiles:
  - mountPath: /etc/talos-extensions/awg.yaml
    content: |
      interfaces:
        - name: mesh-a1b2c3d4
          # ...
```

`talosctl apply-config` with a changed document restarts `ext-awg` with the new config, no reboot
needed.

## Verifying on a node

- `talosctl -n <node> get extensions`: `amneziawg` and `awg`.
- `talosctl -n <node> service ext-awg`: `Running` once converged. It runs with `restart: always`,
  so a failed start retries every 5 s.
- `talosctl -n <node> logs ext-awg`; with `logToConsole: true` its output is in `dmesg` as well.
- `talosctl -n <node> get links` and `get addresses`: every configured interface.
- `curl http://<mesh loopback>:<port>/metrics`: who is connected (`slipmesh_awg_peer_connected`),
  last handshakes, per-peer traffic. Prefer it to `talosctl get routes`, which can disagree with
  the kernel's table; `/proc/net/route` on the node is the table itself.
