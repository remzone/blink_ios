# Blink for iOS

Blink is an iOS 16+ Packet Tunnel VPN client. The legacy tunnel chain is:

`Blink app → Packet Tunnel Extension → WireGuardKit → localhost UDP → free-turn-proxy → VK TURN → VPS → WireGuard server`

The extension owns both Free TURN and WireGuard lifecycles, so the tunnel remains alive while the main app is suspended.

## Vokop / Xray source integration

A separate Xray packet-tunnel extension, VLESS TCP/basic XHTTP import, Vokop VK TURN feed UI and native mobile bridge are now included. **Not yet compiled for iOS or tested on a device.** See [architecture, supported formats, licensing and verification](docs/XRAY-MOBILE.md). Balance remains available through the panel Telegram bot, not an invented mobile API.

Both macOS workflows are manual-only; no build or TestFlight upload starts on push, tag or pull request.

## What is included

- SwiftUI/MVVM application and real `NETunnelProviderManager` control.
- Packet Tunnel Provider using official WireGuardKit.
- Pinned free-turn-proxy source compiled to `Mobile.xcframework` with gomobile.
- Profiles, Simple editor, Advanced JSON editor, import/export.
- App Group file storage and shared Keychain secrets.
- Sanitized in-app logs and tunnel traffic metrics.
- App icon, privacy manifest, entitlements and TestFlight workflow.

## Build on macOS

Install Xcode 16, its command-line tools, Homebrew, Go 1.27.3+, and XcodeGen. Then:

```sh
brew install go xcodegen
make prepare
open Blink.xcodeproj
```

Select your Apple Development Team for `Blink`, `BlinkPacketTunnel` and `BlinkXrayTunnel`. Xcode must create the following identifiers and capabilities:

- `com.blink.tunnel` — App Groups, Keychain Sharing, Network Extensions / Packet Tunnel.
- `com.blink.tunnel.PacketTunnel` — the same capabilities.
- `com.blink.tunnel.XrayTunnel` — separate Xray extension with the same capabilities.
- App Group: `group.com.blink.tunnel`.
- Shared Keychain group: `$(AppIdentifierPrefix)com.blink.tunnel.shared`.

If these bundle IDs are already owned, change all bundle/group identifiers together in `project.yml` and `Blink/Models/SharedConstants.swift` before generating the project.

## Profile requirements

A usable profile needs:

- VPS hostname/IP and Free TURN UDP port.
- Free TURN obfuscation key and active HTTPS VK Call URL.
- WireGuard client private key (the editor can generate it).
- WireGuard server public key.
- Client tunnel address, DNS and allowed IPs.

The generated client public key is shown in the editor and must be configured as a peer on the WireGuard server. The server must route/NAT that peer to the Internet. Blink cannot provision the VPS automatically.

## TestFlight setup

Create the app record for `com.blink.tunnel` in App Store Connect. Add these GitHub Actions secrets:

- `APPLE_TEAM_ID`
- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_PROVISION_PROFILE_BASE64`
- `APPSTORE_KEY_ID`
- `APPSTORE_ISSUER_ID`
- `APPSTORE_PRIVATE_KEY` — raw `.p8` content or its Base64 representation

The API key should have App Manager access. Run the `TestFlight` workflow manually only after separately authorizing an Apple build/upload. It builds the native dependencies, signs the app and extension, archives, and uploads through `xcodebuild -exportArchive`.

Apple may ask for export-compliance information because WireGuard and DTLS use cryptography. Answer this accurately for your distribution jurisdiction; the project deliberately does not hardcode `ITSAppUsesNonExemptEncryption = NO`.

## Security

- WireGuard private and Free TURN obfuscation keys are stored only in shared Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility.
- Provider preferences contain only the selected profile UUID, never keys.
- Exported JSON intentionally excludes secrets.
- ATS is not weakened.
- Logs do not include configurations or secrets.

## Reproducibility

Dependency commits are pinned in `Makefile`:

- WireGuard Apple: `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`
- free-turn-proxy: `aed2839c7dea18d8ade99299fe77973d0730b00b`

`Vendor/`, generated Xcode projects, frameworks and archives are ignored. `make prepare` recreates them.
