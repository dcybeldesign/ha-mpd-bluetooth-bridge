# Changelog

## 2.0.0
- Renamed from "MPD JBL Bridge" to **"Bluetooth Speaker MPD Bridge"** (slug
  `mpd_bluetooth_bridge`, was `mpd_jbl_bridge`) — the add-on works with any
  Bluetooth A2DP speaker, not just a JBL. This is a breaking change for
  anyone who had installed the earlier private v1: reinstall under the new
  slug and re-enter your speaker's MAC address.
- Removed all installation-specific defaults (Bluetooth MAC address).
  `bluetooth_mac` is now a required field with MAC-format validation
  (`match(...)` schema) instead of shipping with a real address as default.
- Added `speaker_name` option (cosmetic label shown in MPD for the output).
- Added `reconnect_interval` option (10–300s, default 30s) to control how
  often the add-on checks the Bluetooth connection.
- Added multi-architecture support (`aarch64`, `amd64`, `armv7`, `armhf`,
  `i386`) via `build.yaml`. Primarily developed and tested on a Raspberry
  Pi 4 (aarch64); other architectures use the same mechanism but haven't
  all been verified in real conditions — feedback welcome.
- Added English + French README, MIT license, this changelog.

## 1.0.0
- Initial working version (private, single installation): MPD server
  bridging Music Assistant to a JBL Flip 3 Bluetooth speaker via a
  Raspberry Pi 4's shared PulseAudio server and Bluetooth adapter.
- Fixed during development: base image tag (`3.19` doesn't exist, use
  `3.18`), missing `bluetoothctl` (wrong package, `bluez` not
  `bluez-deprecated`), MPD startup crash from an unused local music
  database, MPD player unreachable from Music Assistant when addressed by
  the host's external IP (Docker hairpin NAT — use the internal add-on
  hostname instead), and the actual root cause of persistent playback
  failure: the config template used `{{VAR}}` (Jinja/Mustache-style)
  placeholders instead of `${VAR}`, which `envsubst` doesn't expand.
