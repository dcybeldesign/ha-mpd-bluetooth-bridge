# Bluetooth Audio Bridge

A Home Assistant (HAOS) add-on that connects any Bluetooth A2DP speaker
paired with the host and exposes it two ways:

1. A **native `media_player` entity** (DLNA/UPnP), usable directly from
   automations, scripts, or any Home Assistant integration, no music
   server required.
2. An **optional [MPD](https://www.musicpd.org/) server** bridging the
   same speaker to [Music Assistant](https://www.music-assistant.io/) via
   its built-in **MPD Players** provider (the original purpose of this
   add-on).

Both can run at the same time on the same speaker.

*[Lire en français](README.fr.md)*

## Why this exists

The audio output picker on HAOS add-ons only lists physical hardware
(headphone jack / HDMI), never Bluetooth devices paired dynamically with
the host. Home Assistant also has no built-in way to turn "a Bluetooth
speaker paired with the host" into a `media_player` entity on its own.
This add-on fills both gaps: it exposes the speaker as a real
`media_player` entity, and, if you also use Music Assistant, keeps the
original MPD bridge available as an optional second output.

## How it works

- **Native `media_player`**: [gmrender-resurrect](https://github.com/hzeller/gmrender-resurrect)
  exposes the Bluetooth PulseAudio sink as a DLNA/UPnP renderer. Home
  Assistant's built-in `dlna_dmr` integration discovers it automatically
  on the local network (SSDP), no manual entity setup needed.
- **Optional MPD server** (`enable_mpd`, on by default): `run.sh`
  generates `/etc/mpd.conf` from the sink name computed from your
  speaker's MAC address, connects the speaker via `bluetoothctl`, then
  starts MPD. Music Assistant's "MPD Players" provider connects to it
  over the standard MPD protocol port (`6600/tcp`).
- A background loop checks the Bluetooth connection every
  `reconnect_interval` seconds (default 30s) and reconnects automatically
  if the speaker drops (sleep mode, out of range, etc.).
- Both outputs share the same PulseAudio sink and can run simultaneously;
  PulseAudio mixes multiple clients on one sink natively.

## Network access (`host_network`), please read before installing

This add-on requests `host_network: true`. Unlike most add-ons, it does
not run inside Docker's isolated bridge network: it uses the host's
network stack directly, the same level of access as add-ons like
Tailscale or Terminal & SSH.

**Why it's needed**: the native `media_player` relies on SSDP (a
multicast-based discovery protocol) for Home Assistant to find it
automatically. Multicast traffic doesn't reliably cross Docker's default
bridge network, so host networking is a requirement of the DLNA/UPnP
protocol itself, not a convenience choice made for this project.

**What that means in practice**: while running, this add-on is visible
on, and can see, your entire local network, not only the ports it
explicitly declares. If that's not acceptable on your network, this
add-on is not a good fit; there is currently no way to get automatic
DLNA/UPnP discovery working without `host_network`.

## Requirements

- A Home Assistant OS host with a working Bluetooth adapter. Developed
  and tested on a **Raspberry Pi 4** (built-in Bluetooth 5.0). See
  [Portability](#portability-beyond-raspberry-pi-4) below for other
  hardware.
- Shell/terminal access to that host (see step 1 of
  [Pairing your speaker](#pairing-your-speaker-first-time-setup) below if
  you don't have this yet).
- The target speaker must already be **paired** with the host beforehand.
  This add-on only handles connecting/reconnecting an already-paired
  device, not the first-time pairing. Full walkthrough below.
- [Music Assistant](https://www.music-assistant.io/) is only needed if
  you plan to use the optional MPD output (`enable_mpd`). The native
  `media_player` works without it.

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
   `/addons/bluetooth_audio_bridge` on your host if you're not using the
   repository method.
2. Refresh the app store (same ⋮ menu → Check for updates) so the
   add-on appears. It'll show up under a section named after this
   repository (or under "Local apps" if you copied the folder
   manually).
3. Click the add-on, install it, open its **Configuration** tab and fill
   in your speaker's Bluetooth MAC address from the pairing steps above
   (required, see [Configuration](#configuration)), then start it.
4. The native `media_player` entity should appear automatically in Home
   Assistant within a couple of minutes, see
   [Native media_player output](#native-media_player-output-dlnaupnp)
   below if it doesn't.
5. **Only if you want the MPD output** (`enable_mpd`, on by default): in
   Music Assistant, go to **Settings → Player providers**. The **MPD
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
| `speaker_name` | Cosmetic label for the outputs (MPD and the `media_player` friendly name). | `Bluetooth Speaker` |
| `reconnect_interval` | Seconds between Bluetooth connection checks (10-300). | `30` |
| `enable_mpd` | Whether to start the MPD server. The Bluetooth connection and the native `media_player` are unaffected either way; turn this off if you only want the native `media_player` output and don't use Music Assistant. | `true` |

## Native `media_player` output (DLNA/UPnP)

Once the add-on is running and the speaker is paired, Home Assistant
should discover it on its own within a couple of minutes (periodic SSDP
scan) as a `media_player` entity named after `speaker_name`. If it
hasn't shown up after a few minutes, trigger a manual scan: **Settings →
Devices & services → Add integration → DLNA Digital Media Renderer**.

Once the entity exists, you can send audio to it like any other
`media_player`: from the media player card, a script, or an automation
using the `tts.speak` or `media_player.play_media` service with
`media_player_entity_id` targeting this entity.

## Voice PE

**What works today**: since the native `media_player` entity exists,
scripted announcements sent through it, for example an automation
calling `tts.speak` with `media_player_entity_id` set to this add-on's
entity, play on your Bluetooth speaker exactly like on any other
`media_player`. This works whether the automation was triggered by a
Voice PE device or anything else.

**What doesn't (yet)**: a live conversational reply, the answer to a
question you ask a Voice PE device directly, cannot be redirected to a
different `media_player`. The Home Assistant Assist pipeline is designed
to answer back on the same device that captured your voice; separating
capture and reply would require changes to the Voice PE's own ESPHome
firmware, which is outside the scope of this add-on. See
[home-assistant/discussions#689](https://github.com/orgs/home-assistant/discussions/689)
if you want to follow upstream progress on this; as of this writing it's
still open with no built-in solution.

This has not been verified on real Voice PE hardware. Feedback from
anyone who tries it, positive or negative, is welcome via an issue.

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

Beyond the `host_network` access already covered
[above](#network-access-host_network-please-read-before-installing), the
MPD server itself (if `enable_mpd` is on) has no authentication and is
reachable from your local network (not the internet, unless you've
specifically exposed it). This is intentional to keep setup simple,
matching the assumption that your Home Assistant network is already
trusted. Don't expose this port externally without adding your own
protections in front of it.

## Troubleshooting

- **Add-on won't start / crashes immediately**: check the add-on's Log
  tab. A wrong or missing `bluetooth_mac` will fail config validation
  before the container even starts. Double-check you copied the full
  address with colons (`AA:BB:CC:DD:EE:FF`), not dashes or no
  separators.
- **"Failed to open audio output" / no sound on the MPD side, but the
  add-on is running**: this almost always means the speaker isn't
  actually *paired and trusted* yet. "In range" or "powered on" isn't
  enough. Go back through
  [Pairing your speaker](#pairing-your-speaker-first-time-setup) and make
  sure the `pair` and `trust` commands both succeeded (not just
  `connect`). You can check current status any time with
  `bluetoothctl info AA:BB:CC:DD:EE:FF` in a terminal: look for
  `Paired: yes`, `Trusted: yes`, and `Connected: yes` in its output.
- **The `media_player` entity never shows up**: confirm `host_network:
  true` wasn't disabled by mistake in the add-on's Network tab, then try
  the manual scan described in
  [Native media_player output](#native-media_player-output-dlnaupnp).
  Also check the add-on's log for a line confirming `gmediarender`
  started; if it's missing, the add-on didn't build correctly, open an
  issue with the build log.
- **Sound stopped after the speaker lost connection for a while (e.g. low
  battery), even though it looks reconnected now**: the add-on checks
  that the PulseAudio audio sink still exists and re-forces the
  `a2dp_sink` profile if it went missing, which can happen after a burst
  of rapid Bluetooth disconnects/reconnects. If this keeps happening,
  restarting the add-on works around it in the meantime.
- **My speaker keeps disconnecting / doesn't reconnect automatically**:
  confirm `trust` was run during pairing (step 4). Without it, HAOS
  won't allow the automatic reconnection this add-on relies on. You can
  re-run `trust AA:BB:CC:DD:EE:FF` in `bluetoothctl` at any time without
  redoing the full pairing.
- **Music Assistant shows the MPD player as unavailable**: double-check
  `enable_mpd` is on and you used the add-on's *internal hostname*, not
  the host's IP address (see step 5 in Installation).

## Disclaimer

This project is shared freely, put together on my own time. I'm not
responsible for any problems its use might cause (hardware, software, or
otherwise), including anything related to the broader network access
that `host_network: true` grants this add-on (see
[Network access](#network-access-host_network-please-read-before-installing)
above). You use, install, and adapt it entirely at your own risk. The
files are free to use, share, and modify. If you reuse or build on this
work, a credit back to me is appreciated (see below), but nothing here is
provided with any guarantee.

## Support this project

If this add-on has been useful to you, you can support its development:

- [GitHub Sponsors](https://github.com/sponsors/dcybeldesign)
- [Buy Me a Coffee](https://buymeacoffee.com/dcybeldesign)

## Author

[dcybeldesign](https://github.com/dcybeldesign)

## License

[MIT](LICENSE)
