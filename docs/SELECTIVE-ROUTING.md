# Routing and maintenance

Blink 1.0.6 supports panel subscription v3 with `blink.routing.v1`. Settings → Маршрутизация shows the panel list and offers local additions, direct exceptions, full VPN or reset to panel defaults. Changes apply on reconnect; exceptions take priority. Ordinary imported profiles also use the cached panel policy and local overrides.

Domain/FakeDNS and IP rules select the VPN outbound; other destinations use device sockets outside the tunnel. Apps with their own encrypted DNS may need IP rules. Shared CDN ranges can cover unrelated sites. Standard WireGuard and supported Xray single-outbound profiles work in selective mode; AmneziaWG extensions and standalone TUIC/Hysteria1 require full VPN.

The foreground app polls panel maintenance status outside the tunnel every five seconds, displays the server message and refreshes its saved subscription when status changes. During maintenance the managed connection is not presented as healthy; reconnect after completion to apply changed rules. Paid time is extended manually by the administrator, never automatically by the client.

Rebuild BlinkCore and the Xcode project with `make prepare` on macOS before archiving; new gomobile APIs are required. Linux source and native packet checks do not replace Xcode compilation or device validation.
