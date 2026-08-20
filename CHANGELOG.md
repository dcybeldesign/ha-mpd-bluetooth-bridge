# Changelog

## 2.1.0
- Renamed from **"Bluetooth Speaker MPD Bridge"** to **"Bluetooth Audio
  Bridge"** (slug `bluetooth_audio_bridge`, was `mpd_bluetooth_bridge`):
  the add-on is no longer MPD-only. This is a breaking change for
  existing installs: reinstall under the new slug and re-enter your
  speaker's MAC address. `description` updated to match; the GitHub repo
  URL itself was intentionally kept unchanged to preserve its existing
  stars/history.
- Added a **native `media_player` entity**, independent of MPD: the
  Bluetooth speaker is now exposed as a DLNA/UPnP renderer via
  [gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect)
  (compiled from source, no Alpine package exists for it), auto-discovered
  by Home Assistant's built-in `dlna_dmr` integration over SSDP. Runs
  alongside MPD on the same PulseAudio sink; both can play at once.
  `gmediarender` is now given a `--uuid` derived from `bluetooth_mac`
  (stable per speaker, distinct across speakers): without it, every
  install advertised the same fixed default UUID, so two installs for
  two different speakers would collapse into a single `media_player`
  entity instead of two (found and fixed during real-hardware testing).
- Added `enable_mpd` option (default `true`): lets MPD be turned off
  entirely for users who only want the native `media_player` output. The
  Bluetooth connection and the native `media_player` are unaffected
  either way.
- Added `host_network: true`: required for SSDP multicast discovery of
  the native `media_player` to work, since it doesn't reliably cross
  Docker's default bridge network. Documented in the README with its own
  section, since it gives the add-on the same broad network access as
  add-ons like Tailscale or Terminal & SSH.
- Rewrote README.md / README.fr.md: new capabilities documented, a
  dedicated `host_network` disclosure section, and a Voice PE section
  scoped to what's actually possible today (scripted TTS announcements
  to the native `media_player` work; live conversational replies from a
  Voice PE device do not, that would require changes to the Voice PE's
  own firmware, tracked upstream in
  [home-assistant/discussions#689](https://github.com/orgs/home-assistant/discussions/689)).
  French README switched to the formal "vous" register.

## 2.0.1
- Fixed a real-world failure mode: after a burst of rapid Bluetooth
  disconnects/reconnects (e.g. a low-battery speaker), BlueZ could report
  the connection as stable again while PulseAudio's card profile stayed
  stuck on `off` instead of switching back to `a2dp_sink` — no audio sink
  existed, so MPD had nowhere to output sound, with no visible error on
  the Bluetooth side. The monitoring loop now also checks that the
  expected PulseAudio sink exists and forces the `a2dp_sink` profile back
  if it's missing, self-healing without requiring a manual SSH fix.

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
