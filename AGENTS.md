# AGENTS.md

This file is for contributors/agents working in this repository.

## Mission

Build and maintain an unofficial macOS PIA client using Partout as the transport engine, with clean separation between:
- app UX/state
- shared PIA/domain logic
- tunnel runtime

## Important Upstreams

- PIA reference scripts: [pia-foss/manual-connections](https://github.com/pia-foss/manual-connections)
- VPN framework: [partout-io/partout](https://github.com/partout-io/partout)

When behavior is ambiguous, prefer matching `manual-connections` semantics and Partout’s app/tunnel split.

## Code Ownership by Area

- `PrivateClient/`:
  - SwiftUI views + `AppModel`
  - user flows (sign in, server selection, connect/disconnect, logs)
- `PrivateClientShared/`:
  - PIA API client, models, profile builder, shared configuration constants
- `PrivateClientTunnel/`:
  - packet tunnel provider
  - Partout runtime wiring (registry, controller, forwarder, logging)
- `PrivateClientTests/`:
  - unit tests for payload decoding, mapping, token behavior, profile rules

## Non-Obvious Constraints

1. Reuse one profile manager.
- `PIAProfileBuilder.profileID(for:)` intentionally returns one stable ID (`tunnelProfileIdentifier`) so macOS does not accumulate VPN profiles.

2. WireGuard `addKey` must preserve host identity.
- Use `curl --connect-to` with `server.cn` as URL host, mapped to `server.ip`, and validate with PIA CA cert.

3. OpenVPN credentials are token-derived.
- Keep PIA-compatible split: first 62 chars -> username, remainder -> password.

4. DNS fields must be numeric.
- Hostname values like `*.pvt.site` can break module validation. Filter to numeric IPs and fallback to `10.0.0.243`.

5. First-time NE permission can race.
- Connect flow includes a targeted retry for transient `NEVPNError` config failures after first allow prompt.

## Entitlements and Signing

Both app and tunnel targets need:
- `packet-tunnel-provider` capability
- app group `group.uk.tarun.PrivateClient`
- matching keychain group

If connection fails with NE configuration errors, verify entitlements/capabilities first.

## Build/Test Workflow

Preferred to use Xcode MCP:
- Build `PrivateClient` scheme
- Run `PrivateClient` tests

CLI fallback:

```bash
xcodebuild -scheme PrivateClient -destination 'platform=macOS' build
xcodebuild -scheme PrivateClient -destination 'platform=macOS' test
```

## Change Guidelines

- Keep PIA-specific logic out of SwiftUI views; put it in model/shared layers.
- Preserve app/tunnel boundary; do not run VPN protocol engines in app process.
- Add or update tests when changing:
  - API decoding
  - transport mapping
  - credential shaping
  - profile/DNS construction
- Do not remove user-made UI changes unless explicitly requested.
