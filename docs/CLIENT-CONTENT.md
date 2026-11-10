# Client content and navigation

Vokop subscription v1/v2/v3 keeps its existing TURN profiles and adds optional `vpn_profiles`, `bot_url` and `metadata`. Public ordinary links are generated through the existing subscription link provider, only for enabled inbounds attached to the authenticated client. Loopback TURN backends are excluded. Entitlement checks run before credentials are generated. Old clients ignore the additional fields; no credential or schema migration is needed.

`bot_url` is the public username of the configured, running Telegram integration. The bot token is never included. `/account` also supplies this URL so expired or suspended customers can reach subscription management without receiving connection credentials. Bot menu actions remain governed by the existing Telegram integration.

Transport/listener controls now open from Inbounds. Client access, payments, manual extension, feeds, devices and diagnostics open from Clients. `/vokop` remains available for service maintenance, routing and billing policy, with links to the moved sections. Existing backend routes remain unchanged.

Mobile clients store ordinary managed profiles separately from manual profiles, preserve manual entries when the subscription changes, and remove managed profiles when unbound. Unsupported ordinary formats are reported without preventing TURN import. Subscription metadata, emoji and local refresh dates are presentation data. Refresh applies new parameters on the next connection.

The diagnostic recording switch stops new app/native events; it does not delete previously recorded events or OS-owned system logs. Sending and clearing existing records remain explicit user actions. Disabling recording never stops the VPN.
