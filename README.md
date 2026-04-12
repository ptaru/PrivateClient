# PrivateClient

`PrivateClient` is an unofficial macOS client for Private Internet Access (PIA), built with SwiftUI, Network Extension, and [Partout](https://github.com/partout-io/partout).

## Current State

Implemented today:
- Username/password sign-in against the PIA token API
- Region discovery from PIA server list API
- Transport selection: `WireGuard`, `OpenVPN UDP`, `OpenVPN TCP`
- Connect, disconnect, and in-session server switching
- Latency measurement and latency-based region ordering
- Map + sidebar region selection UI
- Session log viewer (app + tunnel log surface)
- Menu Bar extra with status, `Quick Connect`, and disconnect
- Credential/token persistence in Keychain

Not implemented yet:
- Kill switch / firewall rules
- Port-forwarding automation
- Dedicated IP workflows
- Favorites and richer connection rules/policies

## Upstream References

This project follows:
- [pia-foss/manual-connections](https://github.com/pia-foss/manual-connections)
- [partout-io/partout](https://github.com/partout-io/partout)

How this maps in practice:
- PIA semantics:
  - Token endpoint: `https://www.privateinternetaccess.com/api/client/v2/token`
  - Server list endpoint: `https://serverlist.piaservers.net/vpninfo/servers/v6`
  - WireGuard `addKey` flow against selected region server
  - OpenVPN token split compatibility: first 62 chars username, remainder password
- Partout split:
  - App target handles UX, API calls, state, and profile construction
  - Tunnel target executes VPN runtime with `NEPTPForwarder`/`NETunnelController`

## Project Layout

- `PrivateClient/`: SwiftUI app, `AppModel`, app lifecycle, UI
- `PrivateClientShared/`: PIA API client, models, profile builder, shared config
- `PrivateClientTunnel/`: `NEPacketTunnelProvider` + Partout registry/runtime wiring
- `PrivateClientTests/`: unit tests for decoding, mappings, token/profile rules, latency selector behavior

## Architecture Notes

- Stable profile strategy:
  - Uses one fixed profile ID (`PrivateClientConfiguration.tunnelProfileIdentifier`) to avoid accumulating VPN profiles.
- WireGuard setup:
  - Generates key material, calls `addKey`, then builds a WireGuard module from handshake values.
  - Preserves host identity by connecting with `server.cn` and routing via `server.ip`.
- OpenVPN setup:
  - Builds config dynamically with PIA CA cert and token-derived credentials.
- DNS safety:
  - Filters DNS values to numeric IPs only.
  - Falls back to `10.0.0.243` when metadata is hostname-based.
- First-permission reliability:
  - Connect path retries transient first-time NE config failures once after the allow prompt race.

## Entitlements and Signing

Both app and tunnel targets must be configured with:
- Network Extension capability (`packet-tunnel-provider`)
- Shared App Group: `group.uk.tarun.PrivateClient`
- Matching keychain access group

If connect fails with Network Extension configuration errors, verify entitlement/capability setup first.

## Build and Test

Prerequisites:
- Xcode (current project builds/tests on recent Xcode with macOS destination)
- Apple developer signing setup that supports Network Extension for local run
- Optional: `xcodegen` if regenerating `PrivateClient.xcodeproj` from `project.yml`

Commands:

```bash
# Build
xcodebuild -scheme PrivateClient -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme PrivateClient -destination 'platform=macOS' test
```

## Notes for Contributors

- Keep PIA-specific protocol/business logic out of SwiftUI views.
- Maintain app/tunnel process boundaries (protocol engines run in tunnel extension, not app process).
- Add/update tests when changing decoding, endpoint mapping, credential shaping, or profile/DNS construction.

## License

Partout is GPLv3. Treat this project as GPL-compatible when distributing derivatives.
