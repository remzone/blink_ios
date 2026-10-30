# Mobile VK TURN transport provenance

Source: https://github.com/cacggghp/vk-turn-proxy
Pinned upstream commit: `e8a96967dc66f3dbd631596ea6a8b9fe03f9be69`.
Adapted from `client/main.go` (credential request chain and VLESS session setup)
and `tcputil/tcputil.go` (KCP-over-DTLS framing and smux settings). The initial
local source was Vokop's vendored copy at that upstream pin, with its Linux WAN
socket patches. Those Linux marks, CLI signals, OS exits, logging, CAPTCHA
solvers and global caches are not included in this mobile implementation.

Upstream distribution is GPL-3.0 (full upstream LICENSE accompanies this
package); Pion-derived original MIT SPDX headers are retained on the adapted
credential and transport files. `tcputil.go` is unchanged upstream code.
The five application IDs and application keys in credentials.go are the
unchanged *public upstream application constants*, not a user's account,
Bot API, subscription or server administration credentials. Acquired dynamic
VK tokens and TURN passwords remain memory-only and are never logged.

## API and lifecycle

`Start(context, Config, protector)` creates only a loopback listener immediately.
`Addr` is its TCP endpoint; `Status` and the coalescing `Events` channel contain
fixed names: connecting, ready, captcha_required, stopped. `ready` requires
TURN allocation, DTLS handshake, KCP and smux, not merely a listening socket.
`Close` cancels work, closes sockets and waits for all owned worker/forwarder
loops. It is safe to call concurrently or repeatedly. Each network operation
has cancellation/timeout; protector callbacks must return promptly. No global
signals or process exit; separate instances have independent cache/state.

Config.DNSServer is a required explicit literal-IP bootstrap resolver. The
caller must disclose/select it outside the tunnel (e.g. Swift user preference);
there is no platform-resolver or hidden public DNS fallback. DNS uses port53
UDP with Go resolver TCP fallback through the same protection hook.

External DNS and HTTP/TURN TCP sockets use `net.Dialer.Control` before connect.
A rejected or missing protector fails closed. HTTP/3 is disabled because its
independent UDP sockets would evade the configured dialer. HTTP redirects are
not followed. Pion receives numeric server and peer addresses and an already
protected TURN TCP socket; an explicit relay-only network adapter rejects all
Pion socket creation, OS DNS and interface discovery. Pion logs are discarded
even if environment variables request debug output. DTLS/KCP/smux create no additional OS sockets.

CAPTCHA is never solved automatically, nor is a local browser/proxy opened.
A detected challenge publishes `captcha_required`, cancels all transport
workers and stays paused until the owner recreates the client after resolving
access outside this component. No challenge URL/token is disclosed to logs.

## Wire and security limits

Default pinned upstream VLESS mode only: TURN **TCP** → DTLS → KCP → smux.
KCP tuning and smux limits are the unchanged upstream values. The local TCP
stream is an Xray VLESS connection; this package itself is not a VLESS parser.
It is compiled as part of the SAME Go module/framework as Xray, never a second
independent Go runtime in the same extension process.

Upstream DTLS uses `InsecureSkipVerify(true)` with a self-signed certificate.
It encrypts the relay path but does NOT authenticate the VPS certificate.
Don't claim authenticated end-to-end TLS identity. TURN server URIs follow
upstream TCP behavior (including the legacy `turns:` prefix stripping); TLS
TURN is not implemented. XHTTP is a separate direct-Xray profile mode, not an
extra layer magically added to this VLESS TCP tunnel.

No live VK login, relay, payment, iOS/macOS build, entitlement, Apple signing or
physical iPhone test was run. Linux mock lifecycle, protection, credential sequence, silent-TURN cancellation
and full loopback TURN TCP→DTLS→KCP→smux echo tests do not prove production VK
connectivity. The full-wire fixture uses fake credentials and loopback-only
listeners, not VK or OS tunnel/routing settings.
The combined dependency graph may select newer Pion modules due to Xray;
wire-level integration with the server still needs an authorized device/stage
validation. iOS underlying-interface binding is supplied by the owner through
protector; changing physical networks requires closing/restarting the client.
