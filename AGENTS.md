# Contributing to the Rane SL 3 macOS driver

Guidance for anyone changing this repository, human or AI agent. It records the coding standards the
code follows and the lessons that cost real time to learn, so that later work stays consistent with it.
The design and the bug history are in `docs/SL3-AUDIO-ENGINE.md`; the box's command protocol is in
`docs/SL3-COMMANDS.md`. Read both before changing the driver. The driver shares its engine with the SL 2
driver (pepeleedj/Rane-SL2-Macos-ARM-Driver), whose `docs/SL2-AUDIO-ENGINE.md` holds the engine's own bug
catalogue; keep the two drivers' shared code the same where the hardware allows, so they can later share
one code base.

## What is here

| Path | What it is |
|---|---|
| `plugin/SL3Device.m` | The driver: a CoreAudio HAL plug-in (runs inside `coreaudiod`) that drives the box over IOUSBHost |
| `tools/Sl3Api.m` | A replacement for Rane's `Sl3Api.framework`, used by Serato DJ Pro 2.5.x and Rane's control panel |
| `tools/sl3panel.m` | Command-line status and control |
| `tools/controlpanel/` | The SL 3 Control Panel app (SwiftUI) |
| `tools/SL3Passthrough.{h,m}` | Shared client for the driver's HID passthrough (`sl3h`) |
| `tools/sl3dump.m`, `tools/firmware/` | EEPROM read-back, the firmware extractor and the flasher |
| `tools/latency/` | Loopback latency and glitch tests (`make latency`), with a README |
| `tools/hwtest.sh` | The hardware tests in one run (`make hwtest`) |
| `tools/sl3apitest.c` | Sl3Api checked as Serato DJ Pro 2.5.5 calls it (`make apitest`) |
| `tools/install-sl3.sh` | Installs a local build over an installed package and restarts what goes stale |
| `Installer/` | The end-user scripts shipped in the package (Spanish) and the package builder |

`make` builds everything; `make plugin` is the release driver and `make plugin DEBUG=1` adds the
diagnostics and debug commands.

## Safety first

- **Some HID commands write the box's EEPROM or change how it enumerates** (marked ⚠ in
  `docs/SL3-COMMANDS.md`): `0x17` marks the firmware non-bootable, `0x02` writes EEPROM blocks, `0x16`
  marks it bootable and restarts the box, `0x1a` / `0x1b` reconnect it under another product ID, `0x33`
  saves the phono sensitivities to the EEPROM. Never send the others to a working box to "see what
  happens". A box left after `0x17` without a `0x16` comes up with no firmware at its next power-up.
  Earlier notes on this box called `0x17` "probably firmware version": it is not.
- **A wrong flash can brick the box beyond USB recovery.** The recovery then is writing the EEPROM chip
  directly with a SOIC-8 clip and a programmer. `sl3flash` saves the EEPROM first and verifies the whole
  image before it sends `0x16`; keep those guarantees in any change to it. It has not yet been run on an
  SL 3.
- **Don't add gates the official software doesn't have.** The passthrough forwards these commands as
  Rane's driver does; protection belongs in documentation and in the tools, not in a driver-side filter.
- **Never commit Rane's firmware or binaries**: extracted images, disassembly, `Sl3Api` binaries, EEPROM
  dumps. They stay in git-ignored or local directories.
- **Connect the box directly or through one hub.** Isochronous streaming through nested hubs has
  kernel-panicked a Mac inside Apple's XHCI driver.

## Facts about the box

Verify a behaviour on the hardware, or in the firmware or Rane's binaries, before relying on it. The SL 3
driver's code came from the SL 2 driver, and much of the earlier SL 3 code and notes were guesses from
probing. Each fact below says where it comes from; `docs/SL3-AUDIO-ENGINE.md` ("Still open") lists what is
still to be confirmed on the hardware.

- Isochronous endpoints `0x06` OUT and `0x82` IN, 126-byte packets: 7 frames × 6 channels × 3 bytes. The
  samples are packed 24-bit, with no pad byte (c.f. the SL 2's 4-byte samples). (Descriptors.)
- Channels 1-2 Aux, 3-4 Left deck, 5-6 Right deck; the control bytes and reports come in the same order.
  (Rane's labels; confirmed with a loopback cable on each deck: 1 = Aux L, 3 = Left Deck L, 5 = Right Deck L.)
- Boxes in the field run different firmware: one tested runs 2.31, Rane's last driver carries 2.50, and they
  differ (2.31 has no `0x39` report; its DSP boot puts the decks on USB and the rate at 44.1 kHz).
  `docs/SL3-COMMANDS.md` says which is which.
- One LINE/PHONO switch per deck (the SL 2 has one for the box), physical, reported in control bytes 0-2
  and report `0x38`; software can only read them. (Firmware.)
- Each deck's thru is its output-source control byte, 8, 14 or 20 (1 = USB audio, 0 = thru), written with
  `0x33` one byte at a time. (Firmware, Rane's control panel, Serato; observed by OpenSL3.)
- The firmware version comes from HID `0x01` (`02 32` = 2.50); `bcdDevice` is 0x0000 whether the firmware
  runs or not, so a box with no firmware is told by its missing strings. The serial string is the same on
  every box. (Firmware; the no-firmware case is inferred.)
- The box doesn't check the `0x37` heartbeat. (Firmware 2.31 and 2.50, Rane's kext; confirmed on a 2.31
  box: 30 s of USB audio with none.)
- The box powers up at 44.1 kHz with the control bytes at their defaults; only the phono sensitivities are
  kept. (Firmware; contradicts earlier probing notes.)
- Rane's own `Sl3Api.framework` and control panel are the reference for what clients expect: match their
  function signatures and behaviour (from their disassembly), not what seems reasonable.

## Platform lessons (CoreAudio HAL and IOUSBHost)

The full list is under "Platform facts worth knowing" in `docs/SL3-AUDIO-ENGINE.md`. The ones that shape
the design:

- **Real-time completion handling is not available from user space**, and USB completion delivery stalls
  for 5–30 ms regardless of priority. Never design so that audio depends on a completion arriving on
  time: playback keeps a deep schedule of queued transfers and writes audio into them late.
- **Clean up on the USB queue.** Teardown runs on the driver's serial queue (`dispatch_sync`), and work
  from a stopped stream checks the stream generation before touching anything. Release
  `ioDataWithCapacity:` buffers before the next stream claims the interface.
- **Respect the HAL's contracts**: clamp every property write to the caller's `inDataSize`; declare custom
  properties in `kAudioObjectPropertyCustomPropertyInfoList`; keep the zero-timestamp period at or above
  the documented minimum; change the sample rate through the configuration-change handshake; send
  `PropertiesChanged` when the device list or owned objects change.
- **Report latency you have measured** with `tools/latency/rtlat`, not latency you have calculated.
- **The HAL reads safety offsets only at device setup**, so test changes to them after restarting
  `coreaudiod`.
- After `killall coreaudiod`, Control Center, QuickLookUIService and AirPlayXPCHelper keep stale state;
  `tools/install-sl3.sh` restarts them. Judge a change only after that.

## Coding standards

**Structure**
- Group code by subsystem with a prefix: `clk_` (timeline clock), `cap_` (capture), `dp_` (playback deep
  schedule), `usb_`, `hid_`, `dbg_`. Globals start with `g_`.
- Name protocol values: `SL3_CMD_*`, `SL3_CTL_*`, `HID_REPORT_LEN` and friends, each with a comment
  giving the request and reply layout. No bare command numbers in code.
- Debug-only code goes behind `SL3_DEBUG` (`DBG_LOG`, `DBG_DO`, the `dbg_` block). The release build must
  stay quiet: log connect, disconnect, stream start and stop, rate changes, retries, refusals and errors,
  nothing per-cycle. The release build refuses debug commands (`0xF0` and above).
- Code that is replaced is removed from the tip in its own commit, so it stays findable in history. Don't
  leave dead paths or switches for old behaviour in the tip.
- Shared helpers live in one place (`SL3Passthrough`, `tools/latency/common.h`); don't copy them.

**Comments**
- Describe what the code does now and why. No code archaeology: not "the original code used…", "used to",
  "an early version…". Where a contrast helps, use a neutral cross-reference ("c.f. the SL 2, which uses
  `0x0100`"). Commit messages are where the history goes.
- Write for a first-time reader who wasn't part of the debugging: no "your box", no references to our own
  failed experiments, standard terms ("bootloader mode", "EP1 interrupt").
- In any function that reads as a procedure, put a one-line comment before each step saying what the next
  lines do. Lookup tables (the property switch statements) get one separator per section, not per case.
- Keep comments and docs true when the code changes; a stale comment is a bug.

**Docs**
- `docs/SL3-AUDIO-ENGINE.md` is the design record. A fix to the audio engine, connect/status handling or
  the client interfaces adds an entry to its bug catalogue (symptom → cause → fix → test → commit). A fix to
  the engine the SL 2 driver shares belongs in that driver too.
- When moving content between documents, move it verbatim and check nothing was lost.

**Tools**
- Test scripts print a clear PASS or FAIL. Match log lines on text that can't also appear in a counter
  line.
- Tools that only read the box go through the driver's passthrough, so they work while the driver runs.

## Commits and pull requests

- **One bug per commit.** The message gives the symptom, the cause, how it was found and how to test for
  it again. The history is used for regression hunting and as the guide for porting fixes between the
  SL 2, SL 3 and SL 4 drivers.
- **Sign every commit** (GPG). History rewrites with `git filter-branch` drop signatures; after any
  rewrite, check `git log --format=%G? main..HEAD` shows `G` for every commit.
- AI-assisted commits keep a `Co-Authored-By:` line but no session links.
- Stage explicit paths, not `git add -A`; local debug material must not slip in.
- Finish a branch locally (code, comments, build, diff review) before pushing. Once a branch is pushed,
  add follow-up commits rather than force-pushing.
- Keep PRs focused. README restructures go in their own PR. Don't rebuild the committed `.pkg`/`.zip`
  installers in a PR; the maintainer does that.
- A PR description says what was tested on hardware, on what, and what was **not** tested.

## Testing

- Build both `make plugin` and `make plugin DEBUG=1`; build every tool you touched.
- Install with `tools/install-sl3.sh` (needs `sudo`).
- `make hwtest` runs the hardware tests in one go; read `tools/latency/README.md` for the setup.
- Audio changes: a loopback cable from Left Deck Out L to Left Deck In L (channel 3), with the Left deck's
  LINE/PHONO switch on LINE (PHONO's preamp clips the test tones). Then `tools/latency/dptest.sh` and
  `tools/latency/restartcheck.sh`, both PASS, and `rtlat` if latency could have changed. Use the debug
  hooks (`sl3dbg stall`, `sl3dbg errpkts`) to reproduce stalls and errors instead of waiting for them.
- Connect and status changes: unplug and replug while idle and while streaming; check Audio MIDI Setup
  and `sl3panel`.
- Client changes: `sl3apitest` (both slices), Rane's SL 3 control panel, and Serato DJ Pro where possible.
  Serato DJ Pro 4.x / 5.x use the driver directly; only 2.5.x loads `Sl3Api`.
- When testing with someone at the hardware, ask for each physical step explicitly (connect the
  loopback, flip a switch, replug), and order the tests so they need the fewest of those steps.
