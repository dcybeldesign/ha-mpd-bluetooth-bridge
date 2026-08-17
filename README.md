# Bluetooth Speaker MPD Bridge

A Home Assistant (HAOS) add-on that runs a [MPD](https://www.musicpd.org/)
(Music Player Daemon) server whose audio output is forced to a Bluetooth
speaker paired with the host, and exposes that MPD server to
[Music Assistant](https://www.music-assistant.io/) via its built-in
**MPD Players** provider.

*[Lire en français](README.fr.md)*

## Why this exists

Music Assistant's own **Local Audio Out** provider can't target a Bluetooth
PulseAudio sink directly. The audio output picker on HAOS add-ons only lists
physical hardware (headphone jack / HDMI), never dynamically-paired
Bluetooth devices. This add-on works around that by running a small,
dedicated MPD server configured to output straight to the Bluetooth sink.
Music Assistant then connects to it over the standard MPD protocol, which
*is* officially supported.

## How it works

- `run.sh` computes the PulseAudio sink name from the Bluetooth MAC address
  you configure, generates `/etc/mpd.conf` from `mpd.conf.template`,
  connects the speaker via `bluetoothctl`, then starts MPD.
- A background loop checks the Bluetooth connection every
  `reconnect_interval` seconds (default 30s) and reconnects automatically
  if the speaker drops (sleep mode, out of range, etc.).
- MPD exposes port `6600/tcp` (standard MPD protocol port), which Music
  Assistant's "MPD Players" provider connects to directly.

## Requirements

- A Home Assistant OS host with a working Bluetooth adapter. Developed and
  tested on a **Raspberry Pi 4** (built-in Bluetooth 5.0). See
  [Portability](#portability-beyond-raspberry-pi-4) below for other
  hardware.
- Shell/terminal access to that host (see step 1 of
  [Pairing your speaker](#pairing-your-speaker-first-time-setup) below if
  you don't have this yet).
- The target speaker must already be **paired** with the host beforehand.
  This add-on only handles connecting/reconnecting an already-paired
  device, not the first-time pairing. Full walkthrough below.
- [Music Assistant](https://www.music-assistant.io/) add-on installed and
  running.

## Pairing your speaker (first-time setup)

Do this once per speaker, **before** installing the add-on. The add-on can
only reconnect a speaker Home Assistant already knows about; it can't do
the first-time pairing for you.

**1. Get a terminal on your Home Assistant host.**
If typing commands into Home Assistant is new to you, go to **Settings →
Apps** (called "Add-ons" on Home Assistant versions before the mid-2026
rename) → **App store**, search for the official **"Terminal & SSH"**
add-on, install it, start it, then open it from the sidebar. That gives
you a command-line prompt inside Home Assistant, no separate SSH client
needed.

**2. Put your speaker into pairing mode.**
This varies by speaker model, usually holding the power or Bluetooth
button for a few seconds until a light starts blinking. Check your
speaker's own manual if you're not sure how.

**3. In the terminal, start scanning:**
```
bluetoothctl
power on
agent on
scan on
```
After a few seconds you'll see lines streaming in, like:
```
[NEW] Device AA:BB:CC:DD:EE:FF My Speaker Name
```
Look for the line whose name matches your speaker, and note the address
right before the name (the `AA:BB:CC:DD:EE:FF`-style string, that's its
MAC address). Ignore any other devices that show up: phones, TVs, or
other Bluetooth gadgets nearby will often appear too. You only want the
one matching your speaker's name.

**4. Pair, trust, and connect using that address:**
```
scan off
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
quit
```
(replace `AA:BB:CC:DD:EE:FF` with the address you noted in step 3)
- `pair` should reply `Pairing successful`. Most Bluetooth speakers pair
  without asking for a PIN code; if yours does prompt for one, check its
  manual. It's usually `0000` or printed on the device.
- `trust` is what allows the add-on's automatic reconnection to work
  later. Don't skip it.
- `connect` confirms the link works right now. You should hear a
  connection tone from the speaker.

**5. Keep that MAC address handy.** You'll paste it into the add-on's
`bluetooth_mac` option in the next step.

## Installation

1. Add this repository's GitHub URL as a custom repository in Home
   Assistant (**Settings → Apps → App store → ⋮ (top-right menu) →
   Repositories**, paste the URL, close), or copy this folder manually to
   `/addons/mpd_bluetooth_bridge` on your host if you're not using the
   repository method.
2. Refresh the app store (same ⋮ menu → Check for updates) so the
   add-on appears. It'll show up under a section named after this
   repository (or under "Local apps" if you copied the folder
   manually).
3. Click the add-on, install it, open its **Configuration** tab and fill
   in your speaker's Bluetooth MAC address from the pairing steps above
   (required, see [Configuration](#configuration)), then start it.
4. In Music Assistant, go to **Settings → Player providers**. The **MPD
   Players** provider is a single, shared entry: if you don't have it set
   up yet, click **Add a player provider → MPD Players**. If it's already
   configured (for example from another MPD-based bridge), just open the
   existing **MPD Players** entry instead, don't add a second one. Either
   way, add the add-on's **internal hostname** followed by `:6600` to the
   **MPD Servers** field. That field takes one server per line, so if
   there's already an address in there, put the new one on its own line
   underneath rather than replacing it or separating it with a comma.
   To find the hostname, open this add-on's **Info** tab in Home Assistant
   and look under *Controls → Hostname*. Copy that value exactly as shown
   (it typically looks like `local-<something>` or a short generated
   prefix followed by the add-on's name, depending on how you installed
   it, so always check the actual value on your system rather than
   guessing). **Do not** use the host's LAN/Tailscale IP address here: a
   container generally can't reach another container through the host's
   own external IP (a classic Docker "hairpin NAT" limitation). Only the
   internal hostname works reliably.

## Configuration

| Option | Description | Default |
|---|---|---|
| `bluetooth_mac` | MAC address of the Bluetooth speaker (format `AA:BB:CC:DD:EE:FF`). **Required.** | *(none, must be set)* |
| `speaker_name` | Cosmetic label for the MPD output. | `Bluetooth Speaker` |
| `reconnect_interval` | Seconds between Bluetooth connection checks (10-300). | `30` |

## Portability beyond Raspberry Pi 4

Nothing in this add-on is inherently Raspberry Pi-specific. Bluetooth
(`bluetoothctl` over the host D-Bus) and audio (the Supervisor's shared
PulseAudio server) are provided the same way by HAOS regardless of the
underlying hardware. Multi-architecture images are built for `aarch64`,
`amd64`, `armv7`, `armhf`, and `i386` (see `build.yaml`).

That said, this has only been verified in real conditions on a Raspberry
Pi 4. It *should* work unmodified on any HAOS install with a functioning
Bluetooth adapter (other Pi models, x86 NUC-style installs, etc.), but
hasn't been tested on all of them yet. If you try it on different
hardware, please open an issue with the result, good or bad.

## Security note

The MPD server has no authentication and is reachable from your local
network (not the internet, unless you've specifically exposed it). This
is intentional to keep setup simple, matching the assumption that your
Home Assistant network is already trusted. Don't expose this port
externally without adding your own protections in front of it.

## Troubleshooting

- **Add-on won't start / crashes immediately**: check the add-on's Log
  tab. A wrong or missing `bluetooth_mac` will fail config validation
  before the container even starts. Double-check you copied the full
  address with colons (`AA:BB:CC:DD:EE:FF`), not dashes or no
  separators.
- **"Failed to open audio output" / no sound, but the add-on is running**:
  this almost always means the speaker isn't actually *paired and
  trusted* yet. "In range" or "powered on" isn't enough. Go back through
  [Pairing your speaker](#pairing-your-speaker-first-time-setup) and make
  sure the `pair` and `trust` commands both succeeded (not just
  `connect`). You can check current status any time with
  `bluetoothctl info AA:BB:CC:DD:EE:FF` in a terminal: look for
  `Paired: yes`, `Trusted: yes`, and `Connected: yes` in its output.
- **Sound stopped after the speaker lost connection for a while (e.g. low
  battery), even though it looks reconnected now**: since v2.0.1 this is
  handled automatically — the add-on checks that the PulseAudio audio
  sink still exists and re-forces the `a2dp_sink` profile if it went
  missing, which can happen after a burst of rapid Bluetooth
  disconnects/reconnects. If you're on an older version, restarting the
  add-on works around it, or update to get the automatic fix.
- **My speaker keeps disconnecting / doesn't reconnect automatically**:
  confirm `trust` was run during pairing (step 4). Without it, HAOS
  won't allow the automatic reconnection this add-on relies on. You can
  re-run `trust AA:BB:CC:DD:EE:FF` in `bluetoothctl` at any time without
  redoing the full pairing.
- **Music Assistant shows the MPD player as unavailable**: double-check
  you used the add-on's *internal hostname*, not the host's IP address
  (see step 4 in Installation).

## Disclaimer

This project is shared freely, put together on my own time. I'm not
responsible for any problems its use might cause (hardware, software, or
otherwise). You use, install, and adapt it entirely at your own risk.
The files are free to use, share, and modify. If you reuse or build on
this work, a credit back to me is appreciated (see below), but nothing
here is provided with any guarantee.

## Support this project

If this add-on has been useful to you, you can support its development:

- [GitHub Sponsors](https://github.com/sponsors/dcybeldesign)
- [Buy Me a Coffee](https://buymeacoffee.com/dcybeldesign)

## Author

[dcybeldesign](https://github.com/dcybeldesign)

## License

[MIT](LICENSE)
