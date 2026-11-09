# iOS native overrides

`tools/sync-native.py` preserves the explicit iOS override set and reports it.
These files require manual review/merge when the Android mirror changes:

- `mobile/diagnostics*`, `mobile/diagnostic_log*`: runtime target/stats, session-tagged
  numeric diagnostics and typed, rate-limited Xray/WireGuard errors.
- `mobile/engine.go`, `mobile/wg_backend.go`: install safe diagnostic handlers.
- `resources/assets.go`, `resources/assets_test.go`: streaming SHA-256 verification
  and extraction; no complete embedded/on-disk copies in the extension heap.
- `vkturn/diagnostics*`, `captcha.go`, `client.go`, `credentials.go`, `transport.go`:
  bounded stage events without credential-bearing error descriptions.
- `vkturn/direct.go`, `vkturn/transport_metrics.go`: numeric KCP RTT/RTO sampling
  and process-wide retransmit counters; telemetry stops with the transport.
- `mobile/live_integration_test.go`: opt-in real packet/DNS/verified HTTPS acceptance.
- `vkturn/turn_transport_test.go`: sustained echo fixture; keeps the mock peer alive
  until the client reads the queued smux response, avoiding teardown-induced EOF.

- `mobile/vkturn.go`, `vkturn/tuning.go`, `vkturn/tuning_test.go`: iOS advanced
  options (manual TURN address, KCP presets/MTU/window/congestion and cancelable
  per-allocation upload pacing). Optional fields keep old profiles compatible.

Wire framing, server authentication and cryptography are unchanged. The original
KCP settings remain the default; advanced tuning changes only local behavior.
New gomobile exports require rebuilding BlinkCore (`make prepare`). See
[`docs/DIAGNOSTICS.md`](../docs/DIAGNOSTICS.md) for delivery limits and device validation.
