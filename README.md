# PrivateClient

`PrivateClient` is an unofficial, macOS-only Private Internet Access (PIA) client built with SwiftUI + Network Extension + [Partout](https://github.com/partout-io/partout).

It supports:
- PIA username/password login
- Region discovery from PIA server APIs
- Connect/disconnect over `WireGuard`, `OpenVPN UDP`, or `OpenVPN TCP`
- A packet tunnel extension (`NEPacketTunnelProvider`) powered by Partout

## Upstream Projects

This project is built from two upstream references:

- [pia-foss/manual-connections](https://github.com/pia-foss/manual-connections)
- [partout-io/partout](https://github.com/partout-io/partout)

How we use them:

- `manual-connections`:
  - We follow the same public API flow and credential conventions used by PIA scripts:
    - token API: `https://www.privateinternetaccess.com/api/client/v2/token`
    - server list: `https://serverlist.piaservers.net/vpninfo/servers/v6`
    - WireGuard `addKey` endpoint on the selected region server
  - OpenVPN token splitting (first 62 chars as username, remainder as password) is mirrored in `PIAProfileBuilder`.
- `partout`:
  - App target handles UI/state/profile construction.
  - Tunnel target handles runtime transport execution.
  - We register OpenVPN + WireGuard implementations and run them through `NETunnelController` + `NEPTPForwarder`.

## Project Layout

- `PrivateClient/`: macOS SwiftUI app
- `PrivateClientTunnel/`: `NEPacketTunnelProvider` extension
- `PrivateClientShared/`: shared models/API/config/profile builder used by both targets
- `PrivateClientTests/`: unit tests for decoding/mapping/token/profile behavior
- `project.yml`: XcodeGen project definition

## Architecture Notes

- Single reusable VPN profile:
  - The app uses one stable profile ID (`PrivateClientConfiguration.tunnelProfileIdentifier`) and updates it in place per connection choice.
- Protocol-specific build:
  - WireGuard: ephemeral keypair -> `addKey` handshake -> Partout `WireGuardModule`.
  - OpenVPN: generated config (no bundled `.ovpn`), PIA CA cert, token-derived credentials, Partout OpenVPN parser/module.
- DNS safety:
  - Only numeric DNS resolvers are accepted for module fields.
  - If server metadata contains hostname-only DNS, fallback resolver `10.0.0.243` is used.
- First-time permission UX:
  - Connect path retries once for transient `NEVPNError` config races after the initial allow prompt.

## Entitlements / Capabilities

Both app and tunnel targets require:
- App Sandbox
- Network Extension (`packet-tunnel-provider`)
- Shared App Group: `group.uk.tarun.PrivateClient`
- Matching keychain access group

## Build and Test

Prerequisites:
- Xcode 26+
- A developer account with Network Extension entitlement support
- Optional: `xcodegen` if regenerating the project from `project.yml`

Common commands:

```bash
# Optional: regenerate .xcodeproj from project.yml
xcodegen generate

# Build
xcodebuild -scheme PrivateClient -destination 'platform=macOS' build

# Test
xcodebuild -scheme PrivateClient -destination 'platform=macOS' test
```

## Current Scope (v1)

Included:
- Sign in/out
- Region browse/search
- WireGuard + OpenVPN UDP/TCP connect/disconnect
- Basic status + session logs

Not included yet:
- Kill switch
- Port forwarding automation
- Dedicated IP workflows
- Auto-connect/favorites/latency scoring
- Menu bar app UX

## License

Partout is GPLv3, so this project should be treated as GPL-compatible/distributed accordingly.
