# Unified mobile VPN: source design and validation limits

## Scope

The active project is the SwiftUI app plus `BlinkXrayTunnel`, each linking one
`BlinkCore` Go framework. The extension contains Xray, official AmneziaWG (also
serving ordinary WireGuard), and VK TURN. Legacy `Blink/NetworkExtension` sources
remain excluded; WireGuardKit and the independent FreeTurn Go runtime are no
longer project dependencies. Old Swift models/editors remain historical code,
not the main navigation or an automatic configuration migration.

No iOS build, Swift type checking, XCTest, signing, archive, simulator/device run
or TestFlight upload was performed. Syntax parsing and Android/Linux results do
not establish iOS runtime compatibility. The user requested source-only iOS work.

## Packet and configuration paths

- `UniversalProfilesView` → bounded native URI/INI validator → shared Keychain.
  HTTPS feed refresh replaces only nodes belonging to that feed. Xray JSON imports preserve routing/DNS/mux/policy/sniffing and streamSettings; desktop listeners are replaced by the packet stack. External files, API/reverse and socket overrides are rejected. Clash imports nodes only, with an explicit notice that groups/rules/DNS are not applied. Unknown parameters are rejected.
- `XrayVPNController` revalidates the source and refuses to replace a running
  extension's credentials. Provider preferences contain only UUID and mode.
- `XrayPacketTunnelProvider` uses public `packetFlow.readPackets/writePackets`.
  Xray uses the exported packet stack; WG/AWG uses a bounded packet `tun.Device`
  adapter and protected UDP bind. No private utun fd lookup or KVC is used.
- Core endpoint names resolve before installing NE routes. Socket protection
  waits up to two seconds for a satisfied physical NWPath, binds each socket to
  that interface and fails closed if binding fails. An existing but inactive
  `en0` is not used as a fallback. Automatic migration of existing connections
  between physical interfaces is not implemented; reconnect manually.
- Transport readiness is distinct from remote handshake or actual internet.
  Generic core `running` means initialized. The source UI says connectivity is
  unverified. Both source UIs expose separate HTTPS probes; only Android has device validation. iOS diagnostics use URLSession for ordinary/tunnel requests and native ProbeInternet only for physical bypass while the VPN is active; both paths remain unverified on Apple devices.

## Routing and DNS

Xray/VK install IPv4 only, MTU1280 and DNS 1.1.1.1. User Xray JSON retains its own DNS/routing and does not receive the following URI/VK DNS override. Native routing intercepts
port53 UDP/TCP, forwards DNS using TCP through the selected proxy and returns
empty AAAA. No direct/freedom DNS fallback is added. DoH/DoT application traffic
is not rewritten. Endpoint/bootstrap resolution happens in the physical network.

WG/AWG take Address, AllowedIPs, DNS IP and MTU from `.conf`; explicit IPv6 is
supported by the source model. Routes for a family absent from Address are filtered; each DNS server still requires an interface family and covering route. If DNS is omitted, the default
1.1.1.1 must be routable. At most16 peers, MTU1280–9000, Jc≤128 and
Jmin/Jmax/S1–S4≤1280. Desktop configs outside these bounds are rejected.

The manager sets includeAllNetworks/excludeLocalNetworks for Xray/VK and WG full
tunnels; WG split tunnels retain explicit AllowedIPs instead. There are no server
IP exclusions; core sockets alone bind to physical interfaces. Actual Apple
IPv6 no-leak/fast-fail behaviour, LAN access, split-DNS semantics and routing of
remote private subnets require physical-device tests. They are **not verified**.

## VK CAPTCHA before VPN

`VKPreflightAuthorizer` starts VK authorization in the foreground app, before NE
routes. Modern challenges use official VKCaptchaSDK; the legacy image form uses
bounded ephemeral HTTPS and manual input. URLs are restricted to HTTPS VK hosts.
There is no automatic CAPTCHA solver, private VK application cookie access or
SSO integration. Closing/backgrounding the app cancels preflight; timeout5min.

Once TURN is ready, `ExportVKBootstrap` creates a private, profile-bound credential
handoff valid at most90 seconds. It includes TURN secrets and lives only in the
shared Keychain. The extension consumes it before connecting and never exposes it
through provider preferences or logs. It is not a reusable long-term VK login:
a restart or a reconnect after cached authorization expires requires the app.
Stopped/expired sessions or a new challenge stop the extension; unready transport
is bounded to45 seconds after connection, initial extension readiness to40sec.

Compatibility with the pinned experimental VK server preserves DTLS without
server-certificate authentication and inner VLESS without TLS. Application HTTPS
still verifies its own certificates. This mode is not authenticated end-to-end
TLS. Ordinary profiles use their own configured protocol/TLS instead.

## UI audit

Compact width uses phone tabs; regular width uses iPad split navigation. Home is
scrollable with maximum content width, system theme, Dynamic Type and scalable
icon. Forms allow portrait/landscape adaptation. No screenshots/device claims
are made: keyboard, long names, large text, VoiceOver, rotation, iPad multitasking
and dark/light appearances still require a Mac/device review.

## Pinned sources and licensing

- [Xray-core](https://github.com/XTLS/Xray-core), MPL-2.0,
  `0afec66085a85191e9dd2a4a6646c7c9a94688d1`.
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go), MIT,
  v3.1.20260828 / `b5928efb6ca19f0153958460c3d141f04abc5c2e`.
- Share parser adapted from [XTLS/libXray](https://github.com/XTLS/libXray), MIT,
  `7fe8528063e54343af8ba9a37431afc56000de21`; `Native/share/LICENSE` preserved.
- [VK CAPTCHA iOS SDK](https://github.com/VKCOM/vkid-captcha-ios-sdk), package
  revision `95ba7944a79da5e85b064d47833be4426fb763ee` (binary0.1.6).
  Public Swift interfaces inspected; not linked or executed on iOS here.
- VK TURN baseline and GPL notices: `Native/vkturn/UPSTREAM.md`, `Native/LICENSE`.
- New bridge integration: GPL-3.0-only. This does not relicense inherited Swift
  or dependencies. Store distribution and GPL/dependency obligations require a
  deliberate licensing review before publishing.
- Historical excluded FreeTurn code used Happy Bunny License, not MIT; legacy
  attribution is not removed by retiring its target.

`Native/go.mod/go.sum` pin transitive versions; Makefile pins gomobile. A single
Go runtime avoids the prior independent Go frameworks. `tools/sync-native.py`
mirrors Android native source with only the module prefix changed; `--check`
checks byte equality and stale Go files. No Apple compilation occurs in sync.

## Evidence and remaining work

Static project/entitlement/fixture guards and a parser for42 Swift files pass.
They cannot catch Swift types, SDK linkage, actors or provisioning errors.
Android-side native race tests cover real VLESS packets, ordinary WireGuard
against independent official wireguard-go peer, AWG encrypted packets, DNS over
VLESS, protected sockets, manual challenge lifetime and private handoff binding.
TV HTTPS was tested for VLESS without VK/CAPTCHA. These are not iOS tests and do
not certify every protocol/transport against public servers.

Still pending on iOS: generate/build with Xcode, framework symbols and SDK/Swift
compatibility, provisioning, actual packet/TLS/DNS paths, IPv4/IPv6 leakage,
full/split routing, Wi-Fi/cellular transitions, app suspension/extension memory,
battery and reconnects, CAPTCHA presentation and all visual/accessibility checks.

## 0.5.0 source additions

The shared native mirror adds TUIC/Hysteria1 (official sing-quic v0.7.1, GPL-3.0-or-later), bounded yaml.v3 node import (v3.0.1 MIT/Apache-2.0), panel URI adapters, Xray JSON and bundled geodata with source/license hashes in Native/resources/UPSTREAM.md. NativeResources prepares private cached assets in both app and extension. The panel exporter contract fixture contains synthetic credentials only.

NetworkDiagnostics and DiagnosticsView separate physical IP from tunnel IP and Google/YouTube HTTPS204 probes. A direct probe requires XraySocketProtector; tunnel probes require an active connected extension before/after the call. No automatic direct fallback. NSCondition protects the socket protector's shared state, annotated unchecked Sendable; actual Apple interface binding and concurrency still need device testing.

46 Swift files pass syntax parsing and static project guards; no Swift type checking, iOS build or device tests. Android results do not validate Apple NetworkExtension, signing, UI layout or NE routing. See [protocol boundaries](PROTOCOLS.md).
