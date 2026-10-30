# Vokop / Xray mobile implementation

## Status and boundaries

This is source implementation, **not an iOS release or device compatibility claim**.
No macOS/iOS build, signing, TestFlight upload or live VK/VPN test was run for this
change. Both Actions workflows are manual-only; publishing a branch must not
start an Apple build. Swift syntax parsing is not Swift type checking.

Implemented source paths:

1. Direct: public `NEPacketTunnelFlow.readPackets` → Go `tun.Stack.Input` → Xray
   registered TUN connection handler → VLESS TCP or basic XHTTP → server.
2. Vokop feed: same packet bridge → VLESS TCP to loopback → bundled mobile
   `vkturn` library → TURN TCP / DTLS / KCP / smux → pinned VK TURN server → Xray.
3. Existing WireGuardKit / FreeTurn flow remains a **separate extension target**.

The new `BlinkXrayTunnel` links only `BlinkCore.xcframework`. It must never link
legacy `Mobile.xcframework` or WireGuardKit: multiple independently built Go
runtimes in one process are unsupported. The legacy target's pre-existing Go
linkage was not redesigned or revalidated by this change.

There is no private utun fd lookup, KVC or unsupported NetworkExtension accessor.
Xray's exported `Tun`, `NewStack`, `Stack.Input` and registered `ConnectionHandler`
are used directly. We intentionally do **not** call `Handler.Start` (OS TUN) or
`Stack.Start` (fd read loop). Swift supplies IP packets and receives IP packet
callbacks; network settings remain entirely with NetworkExtension.

## Exact dependency baseline

- Xray-core `0afec66085a85191e9dd2a4a6646c7c9a94688d1`, pinned Go module version
  `v1.260327.1-0.20261029083850-0afec66085a8`; upstream MPL-2.0.
- VK TURN source `cacggghp/vk-turn-proxy`
  `e8a96967dc66f3dbd631596ea6a8b9fe03f9be69`; see
  `Native/vkturn/UPSTREAM.md`, preserved notices and license.
- Native bridge/library source is GPL-3.0-only; `Native/LICENSE`.
- Legacy FreeTurn mirror `cacggghp/free-turn-proxy` at the original identical
  commit `aed2839c7dea18d8ade99299fe77973d0730b00b`; Happy Bunny License, **not MIT**.
- Legacy gomobile revision follows that FreeTurn go.mod; new native gomobile is
  separately pinned to `v0.0.0-20261011034528-197770444867`.

Review all dependency/legacy licenses and distribution obligations before any
App Store/TestFlight release. Adding the native license does not relicense
inherited Swift or other upstream files; GPL + store-distribution conditions
require a deliberate distribution decision, not an assumption of compatibility.

## App / panel contract

`GET https://<panel>/<base>/api/vokop/v1/subscriptions/<feedToken>` returns
`vokop.subscription.v1`. Import a dedicated **scoped feed URL**, never an admin
session/password. HTTPS is required, redirects are rejected, response size is
bounded at 128 KiB, and cookies/disk cache are disabled. The URL is stored only in
Keychain. Responses and VLESS IDs are not written to public profile exports.

The parser validates schema, revision, <=31-day lifetime, expiration, profile
count/IDs, UUIDs, ports and VK call URL. The high-water revision for the saved URL is stored in Keychain independently
of the preview, so failed refreshes, navigation and restarts do not reset it.
Forgetting/replacing the saved subscription explicitly resets that identity. Unknown document keys
are ignored by Swift's decoder; this is not a claim of strict duplicate-key JSON
validation. The server remains responsible for authoritative entitlement checks.

A selected VK profile is copied to Keychain with its expiration. The native
engine stops at that expiration; refresh the feed to renew. The old WireGuard
editor is not used to reinterpret VLESS profiles.

**Balance:** no mobile self-account API exists in the current panel. The UI directs
users to `/balance` in the administrator's Telegram bot. No admin API calls or
invented balance numbers are present. A future endpoint needs its own scoped
self-account token and cannot reuse administrator authentication.

Direct mode accepts an individual `vless://` link from a normal 3x-ui
subscription. Supported parameters: `type=tcp|xhttp`, `security=none|tls|reality`,
`encryption=none`, `sni`, `fp`, `pbk`, `sid`, `flow`, `host`, `path`, `mode`.
Vision flow is TCP-only. TLS verification cannot be disabled. Unsupported and
duplicate parameters are rejected, including XHTTP `extra`/`downloadSettings`;
they are not silently lost. Bulk standard subscription fetching is not included.

## VK server-authentication caveat

Compatibility mode preserves the upstream DTLS configuration, which does **not**
verify a server certificate. Inner VLESS/TCP currently has `security=none` to match
the deployed server contract. Consequently this is **not authenticated end-to-end
TLS** and must not be advertised as such. Traffic still needs application-layer
TLS; production use requires an explicit risk decision. A future coordinated
server/feed revision could carry an inner VLESS TLS/REALITY configuration and
verify that identity through the TURN relay. This change does not silently add
those fields or assume a server supports them.

## Lifecycle and networking

- Dedicated extension handles profiles and routes; app suspension does not own
  the core lifecycle. All secrets are read from shared Keychain.
- Direct endpoint DNS resolution occurs before installing VPN routes; TLS SNI
  and XHTTP Host remain the original configured names. No broad endpoint-IP bypass route is added; only the core socket receives
  interface protection. Reconnect to re-resolve a changed endpoint.
- Relay and Xray external sockets require the physical-interface protector;
  unavailable protection fails closed. VK DNS uses its protected resolver. The Vokop screen explicitly configures a
  bootstrap DNS IP (default 1.1.1.1); those VK bootstrap DNS queries intentionally
  bypass the VPN on the protected physical socket. No iOS resolv.conf discovery
  or silent DNS fallback is required.
- IPv4 and IPv6 default routes and DNS use the packet stack. The initial MTU is
  1280. There are no fallback freedom outbounds or inbound proxy listeners.
- Packet input is ordered; buffers are copied across the boundary. Stop is
  idempotent. One active native engine is permitted per extension process.
- VK readiness comes from a constructed smux session, not a listening localhost
  port. `captcha_required` pauses network work; the app reports it without
  CAPTCHA bypass or automatic challenge solving.
- Apple system “connected” means routes/extension are active, **not verified
  remote internet reachability**. The UI states that distinction.

## Verification and next authorized build

Linux checks (no external proxy/VPN):

```sh
cd Native
GOTOOLCHAIN=local go test -race ./...
go vet ./...
```

Tests include public packet-callback ICMP echo, virtual TCP → Xray VLESS → local
mock peer round trip, lifecycle/restart/invalid profiles, and VK mock lifecycle,
protected socket failure and loopback smux relay tests. Local mocks do not prove
live VK authentication, TURN availability or iOS routing.

XCTest source covers Vokop fixture/lifetime/URL validation and VLESS parsing, but
has not been run. A future explicitly authorized macOS check must use Go 1.27.3+,
Xcode/SDKs and `make prepare`, then compile both extensions and run XCTest. The
new Swift-to-gomobile calls must be type checked against generated BlinkCore
headers; Linux header generation and syntax parsing are weaker checks.

Signing requires three App IDs/provisioning identities: app, legacy tunnel and
`com.blink.tunnel.XrayTunnel`, with matching App Group, shared Keychain and
NetworkExtension entitlements. Existing automatic-signing workflow must have
permission to create/update all profiles. No signing assets belong in Git.

Physical-device acceptance: direct TCP/XHTTP TLS/REALITY; VK transport against the
same pinned server; DNS/IPv6; endpoint-route protection; Wi-Fi↔cellular transitions;
sleep/wake; cancellation/reconnect; expiration and revocation; CAPTCHA state;
packet loss/MTU; memory/battery; no unprotected fallback. iOS builds and these
tests remain pending user authorization/environment, not marked passed.
