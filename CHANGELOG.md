# Changelog

All notable changes to the Rane SL3 macOS ARM Driver project are documented in this file.

## [1.4.0] — 2026-11-17

The SL 2 driver's work (pepeleedj/Rane-SL2-Macos-ARM-Driver v1.3.0) ported to the SL 3, and tested on an
SL 3 with firmware 2.31 and 2.50 (debug build; the release build's box-only tests and a glitch test too):
`make hwtest ARGS="--loopback"` 24 of 24; Serato DJ Pro
2.5.5 with turntables; Serato DJ Pro 4.x / 5.x. An 8.5 ms DVS round trip at Serato's
1 ms (48-frame) buffer. What is still open is listed in `docs/SL3-AUDIO-ENGINE.md`.

### Added
- **The SL 2 driver's low-latency engine** in `SL3Device.driver`: deep-scheduled late-write playback,
  a timeline that follows the box's clock, capture placed on the timeline with gaps filled, the early
  capture read (adapted to the SL 3's packed 24-bit samples), input health and the input safety offset
  setting (`sl3panel safety`), stream teardown on the USB queue, and a debug build (`make plugin DEBUG=1`)
  with test hooks (`sl3dbg`).
- **Output volume and mute**, master and per channel (6), in the driver.
- **Settle check:** thru and the sample rate are set again 2 s after the box is opened and 4 s after the
  Mac wakes, as firmware 2.31's DSP boot (after configuration and after every USB suspend) puts the decks
  on USB audio and the rate at 44.1 kHz. Confirmed after a Mac sleep.
- **Routing kept across a replug mid-stream:** the decks come back as they were, so Serato keeps their
  modes (they came back in THRU, sending timecode to the mixer); thru if no stream restarts within 5 s.
- **SL 3 Control Panel.app** (macOS 13+): each deck's LINE/PHONO switch, thru and phono sensitivity,
  level meters (with a note to choose the SL 3 as input while nothing streams), overload flags, output
  volume, sample rate, input safety offset, and the firmware version in red when older than 2.50.
- **Firmware tools** (`tools/firmware/`): `extract-sl3-firmware.py` (from Rane's `RaneSL3_2.0.1f2.pkg`),
  `sl3flash` (over USB, with a backup first and verification before the EEPROM is marked bootable; used to
  update an SL 3 from 2.31 to 2.50; it won't write older firmware than the box runs without `--force`,
  and `--backup-only` saves the EEPROM without writing), and `sl3dump` (EEPROM backup and verify).
- **Tests:** `make hwtest` (the hardware tests in one run), `tools/latency/` (round-trip latency and
  glitch tests), `sl3apitest` (Sl3Api as Serato DJ Pro 2.5.5 calls it).
- **`make package`**: the installer package and zip built from source, with no Rane binaries.
- **Docs:** `docs/SL3-AUDIO-ENGINE.md` (design, bug catalogue), `docs/SL3-COMMANDS.md` (the box's
  protocol, from its firmware and Rane's driver), `AGENTS.md`.

### Changed
- `Sl3Api.framework` matches Rane's 2.0.1f2 export for export (handles, return codes, signatures,
  callbacks from the box's reports).
- `sl3panel` works through the driver, so it works while the driver runs.
- 48 kHz by default (Rane's default, and Serato's for the SL 3); the chosen rate is remembered.
- The reported latency measured on the SL 3 (input device latency 44 frames).
- `sl3panel status` shows the box's own sample rate beside the driver's.
- Device UID `com.rane.sl3.hal.device` (the HAL's saved settings for the old UID don't carry over).
- The early capture read finds arrived frames against a per-position fill template, which audio (even
  clipped) doesn't match, in place of a single repeated mark byte.
- The box's interfaces are no longer offered to other drivers, and the driver takes the HID interface
  back if macOS's HID driver holds it (as after a userspace reboot with the box attached).
- The installer's background is the control panel's icon, drawn at build time.

### Removed
- The 0x37 heartbeat: the SL 3's firmware doesn't check it (confirmed on 2.31 and 2.50).
- Rane's "SL 3 Audio Control Panel" System Settings pane from the installer (the app replaces it).
- The OpenSL3 bridge (`sl3bridge`) and its diagnostic tools.

### Fixed
- `docs/PROTOCOL.md`'s errors, in its replacement `docs/SL3-COMMANDS.md`: `0x17` makes the box unbootable
  (it was listed as a version query); the rate and control bytes reset at power-up.
- The channel order in the instructions: 1–2 Aux, 3–4 Left deck, 5–6 Right deck.
- `install-sl3.sh` installs the driver's `Info.plist` with its binary, so the bundle's version is the
  installed driver's.
- From a code review (none seen on the hardware): playback switched off again before its buffers are freed
  at a stop; a box replugged before its removal was handled is closed and reopened; HID reads retry after a
  refused enqueue and back off after errors; a box reply can't reach the next command after a timeout; the
  status packet is copied consistently; a stale StopIO from before an unplug can't stop a new stream; a rate
  change while streaming sends the rate once; Sl3Api doesn't wait 2 s per call with a box with no firmware;
  one definition of the status packet (`plugin/SL3Status.h`).
- From the SL 2's 1.4.1: a second unplug soon after a replug no longer leaves the decks on thru at the next
  replug; the settle check keeps a routing a client chose instead of putting every deck back on thru; the
  box's configuration is reset only when another driver holds its HID interface; boot mode after a removal
  comes from the open box; `sl3flash` refuses `--dry-run` with `--backup-only`; hwtest reads `SL_LOOP_CH`.

## [1.3.0] - 2026-11-10

- Deep-scheduled playback with late writes from WriteMix, CoreAudio volume and mute controls, hot-plug
  reconnect (pepelee, with Ben XO). The Stems DSP hooks were removed from the driver afterwards.

## OpenSL3 history

- `sl3rec` reports the dominant frequency of each channel (for example a 1 kHz timecode carrier), to check that input runs at the right rate.
- README: recommend 44.1 kHz in Mixxx (its vinyl control can start at 44.1 kHz while the device runs at 48 kHz); troubleshooting for a stuck AirPlay helper.
- README: install from the release download by moving the driver into place; remove the old driver first when upgrading.

## [1.0.1] - 2026-10-09

- Project renamed to OpenSL3 (previously sl3-bridge).
- Builds target macOS 12 and later. The 1.0.0 release download was built for macOS 27 only.

## [1.0.0] - 2026-10-09

The Core Audio driver (`SL3Device.driver`) is now the way to use the SL3; the bridge is kept and documented in `docs/BRIDGE.md`.

- README rewritten around the driver; bridge documentation moved to `docs/BRIDGE.md`.
- `sl3bridge` sets the box to 44.1 kHz at start, so a box left at 48 kHz (by the Core Audio driver or Rane's driver) no longer runs off speed.
- `SL3Device.driver`: 44.1 and 48 kHz, chosen in Audio MIDI Setup or the app and remembered. The driver now sets the box's rate at every start, so a box left at another rate (for example by Rane's driver) no longer runs off speed.
- `sl3ctl set-rate 44100|48000` sets the box's sample rate (vendor command `0x31`). The rate survives power cycles.
- `SL3Device.driver`: hot-plug. Apps using the SL3 keep the device through an unplug (the decks fall back to thru) and resume when it is plugged in again; when nothing uses it, an unplugged SL3 disappears from Core Audio until it is back.
- `SL3Device.driver`: fixed coreaudiod spinning at high CPU (and Core Audio apps hanging) after a few device start/stop cycles.
- New `sl3plugtest` tool (built by `make device-plugin`): loads the driver outside Core Audio, checks every property and cycles IO start/stop.
- `make device-plugin`: Core Audio driver (`SL3Device.driver`) that makes the SL3 a 6-in/6-out device running on its own clock, with no bridge, BlackHole or resampling. About 18 ms in and 22 ms out plus the app buffer; restarts the USB streams if they stop.
- New test tools: `sl3rec` (input levels, channel correlation, callback timing), `sl3tone` (sine on all outputs), `sl3loop` (round-trip latency through a loopback cable).
- `make probe-plugin`: experimental Core Audio plug-in (`SL3Probe.driver`) that only checks whether a HAL plug-in can open the SL3 through IOUSBHost. It publishes no device.
- Lower default latency: about 24 ms in and 29 ms out, down from 33 and 45.
- New options to tune the ring buffers and USB transfer sizes (`--out-target`, `--cap-pkts`, `--cap-xfers`, `--play-pkts`, `--play-xfers`).
- Status output shows the estimated latency and USB packet rates.
- New `sl3usbtiming` tool compares isochronous capture timing between IOUSBHost and libusb.
- Experimental `sl3bridge-iousbhost` build: same bridge on Apple's IOUSBHost framework instead of libusb (audio streams and control channel), with no libusb dependency. It measures the SL3 and loopback clocks from hardware timestamps and sets the resampling ratios from them, which keeps the output ratio steadier.

## [0.1.0] - 2026-10-09

First release.

- `sl3bridge`: passes all six SL3 inputs and outputs to and from BlackHole 16ch, with clock-drift correction.
- Switches the SL3's decks out of analog thru while running, and back to thru on exit.
- Reconnects automatically if the SL3 is unplugged or loses power.
- Diagnostic tools: `sl3probe`, `sl3play` and `sl3ctl`.
- Protocol notes in `docs/PROTOCOL.md`.
