# Sound BlasterX Katana for Omarchy

<img src="preview.png" alt="The Katana panel in the Omarchy bar" width="360">

Bar widget for the Creative Sound BlasterX Katana (USB `041e:3247`, the original Katana).
It keeps the system volume and the speaker's volume bar together, in both directions, lets you
pick the Katana's stored sound profiles, and edits the equalizer and enhancements of the Personal
profile. No Windows, no Creative app.

> **Status.** Developed and tested on one original Katana. Unofficial, not affiliated with
> Creative. Everything below is verified on that unit, but the protocol was worked out by
> observation and from community notes, so other firmware may differ.

## What it does

- **Volume sync.** Each point of the Katana's bar (0-50) is 2% of the system volume. The
  speaker's buttons set the system volume; changing the volume on the PC moves the bar.
  PipeWire's software gain is pinned to 1.0 so the Katana's amplifier does the attenuation.
- **Profiles.** Select the six profiles stored in the speaker, shown as icons. A change made
  on the speaker is announced on screen with the profile's name and icon.
- **Equalizer.** The speaker's own 10-band equalizer (32 Hz to 16 kHz, +-12 dB, plus a preamp)
  with twelve presets. It works on every source the Katana plays, not only the PC.
- **Enhancements.** Switches for Dialog+, Surround and Smart Volume.

The equalizer and the enhancements can be **edited only in the Personal profile**. In the other
profiles the panel shows what that profile holds, read-only, so the factory profiles are never
changed by accident. What you set in Personal is stored in the speaker.

## Requirements

- Omarchy (Quickshell shell), `python3`, `alsa-utils`, and PipeWire's `pactl`, `pw-cli` and `pw-dump`.
- A udev rule so your user can open the Katana's HID interfaces:

      sudo cp udev/71-katana-hidraw.rules /etc/udev/rules.d/
      sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=hidraw

## Install

    omarchy plugin add https://github.com/borferkic/katana-omarchy --enable

then `omarchy bar move io.github.borferkic.katana --section right`.

The panel can show what each profile holds only after the plugin has seen it. Press
**Read profiles** once: it steps through the six profiles for about 15 seconds (the sound changes
as it goes) and ends on the one you had.

## Remove

    omarchy plugin remove io.github.borferkic.katana

That stops the volume sync. Two things stay on purpose, delete them if you want a clean system:

    sudo rm /etc/udev/rules.d/71-katana-hidraw.rules   # the HID access rule from Install
    rm -r ~/.cache/katana-omarchy                       # the plugin's cached state

What you saved in the Personal profile stays in the speaker.

## What it changes on your system

Only while the plugin is enabled, and only for the Katana:

- Volume sync sets the system volume of the Katana's sink and the speaker's own volume (the ALSA
  `Speakers` control) so the two match, and pins PipeWire's software gain on that sink to 1.0.
  Turn it off with the `syncVolume` setting.
- Selecting a profile writes it to the speaker, which keeps it.
- Equalizer and enhancement changes are written to the speaker, and only when the Personal
  profile is the active one; the helper refuses otherwise.
- It writes `~/.cache/katana-omarchy/state.json`, and nothing else in your configuration.

## Usage

| Input | Action |
| --- | --- |
| Left click on the bar icon | Open the panel |
| Right click | Refresh |
| `Esc` / `r` | Close / refresh |
| Equalizer slider | Drag, scroll, or double-click to reset to 0 dB |

Settings: `syncVolume` (default on) and `announceProfile` (default on).

## How it works

`bin/katana.py` has these commands: `daemon` (volume sync and profile learning, one JSON event
per line, single instance), `status`, `profile N`, `learn`, `volume N` and `hw JSON`.

- The Katana reports its bar as `5a 23 03 00 <level>`: on HID interface 3 for the buttons,
  on interface 4 for changes made from the PC.
- The bar follows the ALSA `Speakers` control (0-128) through a non-linear curve, measured
  with a sweep and stored in the script.
- Profiles are selected with `5a 1a 03 00 02 <n>` on interface 4; the speaker acknowledges
  with `5a 1a 02 02 <n>` and then reports what changed with `5a 11` frames.
- Those frames carry `(page, register, float32)` entries, only for registers that differ from the
  previous profile, so the daemon applies them to a running model and keeps a snapshot per
  profile. Registers on page `0x96`: `09` equalizer on/off, `0a` preamp (dB), `0b`-`14` the ten
  bands (dB), `70` Smart Volume, `71` Surround, `72` Dialog+ (2.0 on, 0.0 off).
- A write is `5a 12 07 01 <page> <register> <float32>`; the speaker answers `5a 02 02 12 00` and
  keeps the change in the active profile. The equalizer and preamp registers were checked by
  measuring a 1 kHz tone through the speaker's own capture while changing them.

## Development

The shell caches a plugin's QML while it runs: after editing a `.qml` file, run
`omarchy restart shell`. Keep the plugin as a real folder under `~/.config/omarchy/plugins/`;
the shell's file watcher does not follow symlinks.

## License

MIT
