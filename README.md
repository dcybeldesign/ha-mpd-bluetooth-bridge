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
- **Pairing page** (Home Assistant ingress, opened with **Open Web UI** or
  from an optional **Bluetooth Audio** sidebar panel): a small web page
  served by busybox `httpd`, with shell
  scripts calling `bluetoothctl`. It scans for Bluetooth Classic audio
  devices, pairs and trusts them, and writes the speaker you pick into
  the add-on's own configuration through the Supervisor API.
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
- A Bluetooth speaker you can put into pairing mode. No terminal needed:
  the add-on's own **Bluetooth Audio** panel finds and pairs it, see
  [Pairing your speaker](#pairing-your-speaker-first-time-setup) below.
  Only speakers that ask for a PIN code still need the
  [manual procedure](#manual-pairing-fallback), which requires terminal
  access to the host.
- [Music Assistant](https://www.music-assistant.io/) is only needed if
  you plan to use the optional MPD output (`enable_mpd`). The native
  `media_player` works without it.

## Pairing your speaker (first-time setup)

Do this once per speaker, straight from the add-on's own pairing page.

**1. Install and start the add-on** (see [Installation](#installation)
below). On a first install, leave `bluetooth_mac` empty: the add-on then
starts in *setup mode*, with only its pairing page running.

**2. Open the pairing page.** On the add-on's **Info** tab, click
**Open Web UI**. To get a **Bluetooth Audio** shortcut in the Home
Assistant sidebar instead, turn on **Show in sidebar** on that same tab:
it's off by default. The page is only available to Home Assistant
administrators.

**3. Put your speaker into pairing mode.**
This varies by speaker model, usually holding the power or Bluetooth
button for a few seconds until a light starts blinking. Check your
speaker's own manual if you're not sure how. If the speaker is currently
connected to a phone, disconnect it there first: many speakers only
accept one connection at a time.

**4. Click Scan.** After about 30 seconds, nearby Bluetooth audio devices
show up by name. Phones, TVs, and other non-audio devices are hidden
unless you tick *Show non-audio devices*.

**5. Click Pair next to your speaker.** The add-on pairs, trusts, and
connects it. You should hear a connection tone from the speaker, and its
*Paired*, *Trusted* and *Connected* badges turn green. *Trusted* is what
allows the add-on's automatic reconnection to work later.

**6. Click Set as primary**, then confirm the name you want to see in
Home Assistant. The add-on saves the speaker into its own configuration
(`bluetooth_mac` and `speaker_name`) and restarts by itself; the native
`media_player` then shows up as described in
[Native media_player output](#native-media_player-output-dlnaupnp). For
another speaker, pair it the same way and click **Add as extra** instead,
see [Multiple speakers](#multiple-speakers).

### Manual pairing (fallback)

If the pairing page can't pair your speaker (typically an older model
that asks for a PIN code), pair it once by hand from a terminal, then
enter its MAC address in the add-on's `bluetooth_mac` option.

**1. Get a terminal on your Home Assistant host.**
If typing commands into Home Assistant is new to you, go to **Settings →
Apps** (called "Add-ons" on Home Assistant versions before the mid-2026
rename) → **App store**, search for the official **"Terminal & SSH"**
add-on, install it, start it, then open it from the sidebar. That gives
you a command-line prompt inside Home Assistant, no separate SSH client
needed.

**2. Put your speaker into pairing mode**, as in step 3 above.

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

**5. Enter that MAC address** in the add-on's `bluetooth_mac` option
(Configuration tab), then start or restart the add-on. The pairing page
will then show it with its *Paired*, *Trusted* and *Connected* badges.

## Installation

Fastest way: click the button below, it opens your Home Assistant instance
with this repository's URL pre-filled, just confirm to add it.

[![Add repository on my Home Assistant][add-repo-shield]][add-repo-badge]

1. If you didn't use the button above, add this repository's GitHub URL as
   a custom repository in Home Assistant manually (**Settings → Apps →
   App store → ⋮ (top-right menu) → Repositories**, paste the URL, close),
   or copy this folder manually to `/addons/bluetooth_audio_bridge` on
   your host if you're not using the repository method.
2. Refresh the app store (same ⋮ menu → Check for updates) so the
   add-on appears. It'll show up under a section named after this
   repository (or under "Local apps" if you copied the folder
   manually).
3. Click the add-on, install it, then start it. On a first install,
   leave `bluetooth_mac` empty and follow
   [Pairing your speaker](#pairing-your-speaker-first-time-setup) from
   the add-on's **Bluetooth Audio** panel. If you already paired the
   speaker by hand, fill in its MAC address in the **Configuration** tab
   first (see [Configuration](#configuration)).
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
| `bluetooth_mac` | MAC address of the primary Bluetooth speaker (format `AA:BB:CC:DD:EE:FF`). Filled in automatically when you pick a speaker on the pairing page; leave empty on a first install to start in setup mode (pairing page only). | *(empty)* |
| `speaker_name` | Cosmetic label for the outputs (MPD and the `media_player` friendly name). | `Bluetooth Speaker` |
| `reconnect_interval` | Seconds between Bluetooth connection checks (10-300). | `30` |
| `enable_mpd` | Whether to start the MPD server. The Bluetooth connection and the native `media_player` are unaffected either way; turn this off if you only want the native `media_player` output and don't use Music Assistant. | `true` |
| `default_volume` | Volume (%) automatically restored if the speaker's PulseAudio sink is ever found muted or at 0% (otherwise stays silent indefinitely, even across reboots). Never overrides a volume you've deliberately set as long as it isn't 0%. | `70` |
| `extra_speakers` | Optional list of additional speakers (`mac` + `name` each), editable straight from the Configuration tab. See [Multiple speakers](#multiple-speakers). | *(empty)* |

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

## Multiple speakers

You're not limited to one Bluetooth speaker. The `extra_speakers` option
(a list of `{mac, name}` entries, added from the pairing page with **Add
as extra**, or straight from the add-on's Configuration tab — no YAML
editing needed) lets you register additional
speakers alongside the primary one (`bluetooth_mac`/`speaker_name`). Each
speaker gets:

- its own Bluetooth connection, monitored and reconnected independently
  of the others;
- its own PulseAudio sink;
- its own native `media_player` entity in Home Assistant, so you can pick
  exactly which speaker a given `play_media`/`tts.speak` call goes to.

This gives you multiple independently selectable outputs, not
synchronized multi-room playback: each speaker plays whatever you send
to it, on its own — there's no built-in way to send the same audio, in
sync, to several speakers at once.

MPD (and by extension Music Assistant's "MPD Players" provider) stays
attached to the primary speaker only; there's no clean way to expose
several MPD outputs as separate `media_player` entities, so extra
speakers are only reachable through the native `media_player` path.

**Music Assistant shows extra speakers with a generic or duplicate name**
(e.g. two speakers both labeled "Bluetooth Speaker"): this is a
naming/caching quirk in Music Assistant's own DLNA player discovery, not
something this add-on controls — Home Assistant itself already shows the
correct name (`speaker_name` for the primary speaker, or the `name` you
set in `extra_speakers`). If Music Assistant confuses two players, rename
them directly there: **Music Assistant → Settings → Players → pick the
player → the pencil icon** next to its name.

**Changing the primary speaker moves its entity.** The primary speaker's
native `media_player` always listens on port 49494, and Home Assistant
ties the entity to that address. If you set another speaker as primary,
the existing entity switches to that speaker and can take its name.
Extra speakers each listen on a fixed port derived from their MAC
address, so their entities stay with them however the list is ordered.

If you add a speaker while the add-on is already running and its
`media_player` entity doesn't show up after a few minutes, try a full
**Home Assistant Core restart** (Settings → System → Restart, not just
the add-on) — this forces a fresh SSDP scan and reliably surfaced it in
our testing.

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
Pi 4, plus one community report on a **Chromebox** (x86, `amd64` image,
with a Bluetooth 6.0 USB dongle) working well. It *should* work unmodified
on any HAOS install with a functioning Bluetooth adapter (other Pi models,
x86 NUC-style installs, etc.), but hasn't been tested on all of them yet.
If you try it on different hardware, please open an issue with the
result, good or bad.

## Security note

Beyond the `host_network` access already covered
[above](#network-access-host_network-please-read-before-installing), the
MPD server itself (if `enable_mpd` is on) has no authentication and is
reachable from your local network (not the internet, unless you've
specifically exposed it). This is intentional to keep setup simple,
matching the assumption that your Home Assistant network is already
trusted. Don't expose this port externally without adding your own
protections in front of it.

The pairing page is only reachable through Home Assistant's ingress, so
behind your Home Assistant login, and only for administrators. Because
the add-on uses `host_network`, its web server deliberately listens only
on the internal Supervisor network address and rejects any client other
than the Supervisor's ingress proxy: it isn't reachable from your LAN.

## Troubleshooting

- **Add-on won't start / crashes immediately**: check the add-on's Log
  tab. A malformed `bluetooth_mac` will fail config validation before
  the container even starts. Double-check you copied the full address
  with colons (`AA:BB:CC:DD:EE:FF`), not dashes or no separators. An
  empty `bluetooth_mac` is fine: the add-on then starts in setup mode,
  see [Pairing your speaker](#pairing-your-speaker-first-time-setup).
- **"Failed to open audio output" / no sound on the MPD side, but the
  add-on is running**: this almost always means the speaker isn't
  actually *paired and trusted* yet. "In range" or "powered on" isn't
  enough. Open the add-on's **Bluetooth Audio** panel: the speaker's
  *Paired*, *Trusted* and *Connected* badges should all be green. If one
  isn't, click **Pair** next to it (on an already-paired speaker it only
  re-trusts it, without redoing the pairing), or go back through
  [Pairing your speaker](#pairing-your-speaker-first-time-setup).
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
  check that its *Trusted* badge is green on the pairing page. Without
  it, HAOS won't allow the automatic reconnection this add-on relies on.
  Clicking **Pair** on an already-paired speaker only re-trusts it, it
  doesn't redo the full pairing (or run `trust AA:BB:CC:DD:EE:FF` in
  `bluetoothctl`).
- **Pairing fails on the pairing page**: make sure the speaker is in
  pairing mode *when you click Pair* (many speakers leave pairing mode
  after a minute or two), close to the host, and not connected to a
  phone. Speakers that ask for a PIN code can't be paired from the page:
  use [Manual pairing (fallback)](#manual-pairing-fallback). The error
  shown on the page, and the add-on's Log tab, include the reason
  reported by Bluetooth.
- **The Bluetooth Audio panel doesn't open, or shows an error**: look for
  a `Starting the pairing web UI` line in the add-on's Log tab. If
  there's an error about the ingress address/port instead, restart the
  add-on; the audio bridge itself keeps working either way.
- **Another Bluetooth audio add-on is installed** (for example Bluetooth
  Audio Manager): don't let two add-ons manage the same speaker. Each one
  reconnects it on its own and they end up fighting over the connection.
- **Music Assistant shows the MPD player as unavailable**: double-check
  `enable_mpd` is on and you used the add-on's *internal hostname*, not
  the host's IP address (see step 5 in Installation).
- **A newly added extra speaker's `media_player` never shows up**: same
  root cause as above, but specifically after adding a speaker to an
  already-running install — try a full Home Assistant **Core** restart
  (not just the add-on), see [Multiple speakers](#multiple-speakers).
- **Crackling, stuttering, or brief audio dropouts, especially on a
  Raspberry Pi 4**: the Pi 4's onboard Bluetooth and Wi-Fi share the same
  2.4GHz radio and antenna, which commonly causes exactly this kind of
  glitch under real-world use — it's a hardware limitation, not something
  this add-on can fix in software. A cheap external USB Bluetooth dongle
  with its own antenna (e.g. one based on the common CSR8510 chipset)
  reliably works around it: BlueZ picks it up automatically as an
  additional controller, no configuration change needed here. Run
  `bluetoothctl list` to confirm it's active as the `[default]`
  controller.
- **Renamed a speaker in the add-on, but its `media_player` entity kept
  the old name**: this is how Home Assistant's DLNA integration works,
  not something the add-on controls. The entity name is set once, when
  Home Assistant first discovers the speaker, and is never updated
  afterwards. The add-on keeps the same identifier for a speaker (derived
  from its MAC address), so Home Assistant still sees the same device.
  Rename the entity directly in Home Assistant (**Settings → Devices &
  services → Entities**), or delete that speaker's **DLNA Digital Media
  Renderer** entry and let Home Assistant rediscover it with the new name
  (its entity ID may change, so check your automations).

## How this was built

The idea, the real-hardware testing, and the decisions on how it should
behave are mine. The code, and most of the English on this page (not my
first language), were written with Claude, an AI assistant, from the
very first commit. Only a couple of commits explicitly carry a
`Co-Authored-By` line for it; the habit of adding that line came later
and wasn't applied retroactively to the rest of the history.
The pairing page is the exception: it was contributed by cddu33, see
[Contributors](#contributors).

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

## Contributors

- [cddu33](https://github.com/cddu33): the pairing page
  ([#4](https://github.com/dcybeldesign/ha-mpd-bluetooth-bridge/pull/4))

## License

[MIT](LICENSE)

[add-repo-shield]: https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg
[add-repo-badge]: https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdcybeldesign%2Fha-mpd-bluetooth-bridge
