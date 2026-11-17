# Rane SL 3 — USB command protocol

> ⚠ **Commands `0x02`, `0x16` and `0x17` write the box's boot EEPROM, and `0x16`, `0x1a` and `0x1b`
> disconnect the box from USB.** `0x17` alone marks the firmware non-bootable (EEPROM byte 0 := `0xC0`),
> so the box comes up as a bare FX2 at the next power-up. `0x16` writes `0xC2` (bootable) and restarts
> the box *whether or not* the EEPROM holds a complete image. `0x1a` re-enumerates the box as product
> ID `0x0003` until it is power-cycled. `0x33` also writes the EEPROM, but only three settings bytes
> (`0x3FC0`–`0x3FC2`), and only when they change.
>
> **`0x17` is not a version query** (earlier notes on this box guessed so): sending it to a working
> box makes it unbootable at the next power cycle. The firmware version is `0x01`.
>
> Any program on the Mac can send any command through the HAL driver's `'sl3h'` property (below):
> the driver does not filter opcodes, as Rane's software did not either. Only `tools/firmware/sl3flash`
> sends the EEPROM commands.

This document lists every command the SL3's 8051 firmware accepts on its HID-style interface, the
reports the box sends unasked, and what the firmware does with the 22 "audio control" bytes. It
covers both firmware images that Rane's driver 2.0.1f2 embeds:

- the **running firmware** (v2.50, built 2013-12-17) — booted from the box's I2C EEPROM; and
- the **bootstrap** (v2.25, built 2009-10-16) — a RAM-loaded copy of the same command set without
  the audio side, used to rewrite the EEPROM.

Source: the two images as embedded in Rane's `Sl3Api.framework` 2.0.1f2
(`tools/firmware/extract-sl3-firmware.py` extracts them from your own copy), disassembled as 8051
code; and Rane's kext `Sl3Driver.10.9.kext`, `Sl3Api` and control panel from the same package.
Addresses are 8051 CODE addresses in the running firmware unless marked "boot". "Read" means taken
from the code; "inferred" means a conclusion from how the code uses something. **None of this has
yet been confirmed on an SL 3 by this project** beyond what the OpenSL3 project observed (the
transport, `0x31`, `0x32`/`0x33` and the thru bytes); `make hwtest` checks the parts the driver
relies on.

## Hardware, as seen from the firmware

- **Cypress EZ-USB FX2** (8051), boots from an I2C EEPROM at address `0x51` (2-byte addressing,
  so at least 16 KiB: the firmware reads `0x3FC0`).
- **A Freescale DSP56300-family DSP** on the same I2C bus at address `0x5C` (its serial host
  interface; inferred from the address and from the boot data, which consists of 24-bit
  DSP563xx instruction words such as `movep #…,x:$FFFFxx`). The DSP does the audio processing:
  the 8051 boots it from the EEPROM and then only passes it the sample rate and the control bytes.
- The audio samples bypass the 8051: EP6 OUT and EP2 IN run in **slave-FIFO mode** (`IFCONFIG =
  0xCB`, asynchronous, 8-bit) towards an external master (the DSP or glue logic; not traced).
- There is **no FPGA** (unlike the SL 2) and **no timer interrupt**: the firmware's only periodic
  event is the USB start-of-frame interrupt (8 kHz at high speed).

## Transport

- USB interface 3: HID class, 28-byte vendor report descriptor (usage page `0xFF00`), 64-byte input
  and output reports, no report IDs.
- Commands on **EP1 interrupt OUT** (`0x01`), replies on **EP1 interrupt IN** (`0x81`), interval 1.
- The firmware only looks at EP1 while the device is configured (IRAM `0x1E` ≠ 0; `0x1BB6`).
- This project's HAL driver (`plugin/SL3Device.m`) owns the interface while it runs and offers it
  to other programs through CoreAudio custom properties: writing a 64-byte command to `'sl3h'`
  sends it and keeps the reply for that process, which its next read of `'sl3h'` returns; `'sl3q'`
  gives each process the box's unsolicited reports. `tools/Sl3Api.m` replaces Rane's
  `Sl3Api.framework` on top of these, with the same functions; `tools/SL3Passthrough.m` is the
  minimal client the tools use.
- Every command gets at most one reply. Unsolicited reports go out only when no command is waiting
  and EP1 IN is free (`0x0100–0x0111` → `0x059D`).
- At **full speed** the box offers a different configuration with only the HID interface (100 mA
  instead of 400 mA), and `SET_INTERFACE` on the audio interfaces is refused unless configured at
  high speed (`0x1A4A`, `0x1AB5`). Audio needs a USB 2.0 high-speed port; `0x0a` tells.

### Report layout

| byte | request | reply |
|------|---------|-------|
| 0 | opcode | opcode echoed; `0xFF` = rejected or unknown command |
| 1–4 | host-chosen 32-bit tag | the request's tag, copied back unchanged (`0x0571`) |
| 5… | arguments | results; unused bytes are whatever EP1 IN held before (not cleared) |

Unlike the SL 2, **every** reply in the SL3 copies the tag, including `0x00` and rejections. The
firmware never interprets the tag, so its byte order is the host's choice.

## Commands (running firmware)

Dispatch table at `0x0124` (Keil sparse switch). "boot" gives the bootstrap's handler; `—` = the
bootstrap does not implement it (replies `0xFF`).

| op | run | boot | request | reply / effect |
|----|-----|------|---------|----------------|
| `0x00` | `015B` | `0859` | — | ping: `[0]=00` + tag |
| `0x01` | `0166` | `0864` | — | **firmware version**: `[5]` major, `[6]` minor, `[7..10]` 32-bit build stamp, big-endian. Running firmware `02 32` (2.50), stamp `52 AF C4 CB`; bootstrap `02 19` (2.25), stamp `4A D8 F3 53` |
| ⚠ `0x02` | `0392` | `0A69` | `[5..6]` EEPROM address (BE), `[7..38]` 32 data bytes | write 32 bytes to the EEPROM, then reply exactly like `0x03` (read-back). Allowed only after `0x17`, **or** if this very request has address `0000` and `[7]=C0`. Any write to address `0000` has its bytes `[7..11]` forced to `C0 C5 1C 01 00` (non-bootable header, VID `1CC5`, PID `0001`). Not enabled → `0xFF` |
| `0x03` | `03D8` | `0AAF` | `[5..6]` EEPROM address (BE) | read 32 EEPROM bytes: `[5..6]` address echoed, `[7..38]` data. Read-only; works at any time. Address `0000`, byte `[7]`, is the boot byte: `C2` = boots the firmware, `C0` = boots as a bare FX2 |
| `0x06` | `0163` | `0861` | — | does nothing and **sends no reply** |
| `0x0a` | `019C` | `089A` | — | USB state in `[5]`: 0 = unconfigured, 1 = full-speed configuration, 2 = high-speed configuration (`0x23D6`) |
| ⚠ `0x16` | `0433` | `0B0A` | — | write `C2` to EEPROM byte 0 (bootable), reply, wait for the reply to leave, power down the audio side (PD0/PD1/PD2 low), disconnect, wait 1 s, pulse PA3 low (inferred: resets the FX2, which reboots from the EEPROM). Does **not** check the `0x17` enable |
| ⚠ `0x17` | `0409` | `0AE0` | — | write `C0` to EEPROM byte 0 (**non-bootable**) and enable `0x02` until the box resets; reply `0x17` + tag |
| ⚠ `0x1a` | `04D1` | — | — | reply, (if control byte 21 = 0: DSP "D1" := 0, PD1 low), PD0 low, disconnect, wait 1.5 s, reconnect with the device descriptor at `0x1112`: **PID `0x0003`**. Not stored; a power cycle or `0x1b` restores PID `0x0001` |
| ⚠ `0x1b` | `04D1` | — | — | the same, reconnecting as PID `0x0001` (the normal identity, descriptor `0x1100`) |
| `0x30` | `01AB` | `08A9` | — | sample rate in `[5..6]`, big-endian |
| `0x31` | `01BE` | `08BC` | `[5..6]` rate, big-endian | set the sample rate: only `AC 44` (44100) and `BB 80` (48000); anything else → `0xFF`. The DSP is told from the main loop (`0x228B`). Reset to 44100 at every power-up (`0x2259`) |
| `0x32` | `020C` | `090A` | — | the 22 control bytes in `[5..26]` (indices 0–20 from IRAM `0x08–0x1C`, index 21 from IRAM `0x1F`); clears a pending `0x38` report |
| `0x33` | `023B` | `0940` | `[5]` first index, `[6]` count, `[7..]` values | write control bytes; see "Control bytes". Reply `0x33` + tag, no status. Then sends indices 0–20 to the DSP (`0x249F`) and saves indices 3/9/15 to the EEPROM if changed (`0x102C`) ⚠ |
| `0x35` | `02DA` | `09B1` | — | six overload flags in `[5..10]` (each 0 or 1); clears a pending `0x34` report |
| `0x36` | `0322` | `09F9` | `[5]` on/off | enable (`[5]` ≠ 0) or disable (`[5]` = 0) the unsolicited reports. Only `[5]` is read |
| `0x37` | `0338` | `0A0F` | `[5..12]` 8-byte challenge | `[5..12]` 8-byte response (see "`0x37`") |
| other | `056B` | `0BA7` | — | `[0]=FF` + tag |

Opcodes the SL 2 has and the SL3 does not: `0x41` (Hidi messages), `0x45` (port status). There is
no serial-number, port-status or "device info" command, and no `0x04` or `0x10`. The serial
string is a constant, `"SL3.01.00"`, in the descriptor (same on every box).

### Details

- **`0x37` challenge/response.** The handler copies `[5..12]` to XDATA `0x2801`, runs the routine at
  `0x0804` on it and copies the result back. The routine is shaped like XXTEA (btea) with two 32-bit
  words: delta `0x9E3779B9` (inline constant at `0x0823`), `e = (sum >> 2) & 3`, 32 rounds
  (`0x0839`; 6 + 52/2). The key was not extracted. The routine works only on XDATA scratch
  `0x2801–0x2827`; it touches no port, no USB register, no flag and does not talk to the DSP. **There
  is no watchdog**: no timer, counter or flag is reset by `0x37` or by EP1 traffic in general, and no
  code path changes the audio state on a timeout. The firmware's only time bases are the SOF counter
  that schedules the overload poll and busy-wait delays. A host need not send `0x37` at all, and
  need not check the answer.
- **`0x31` / EP0 rate control.** The rate can also be set with the UAC 1.0 *endpoint* sampling-frequency
  control: `bmRequestType 0x22` (SET_CUR, any `bRequest`) or `0xA2` (GET_CUR), `wValue 0x01xx`,
  `wIndex 0x06` or `0x82`, 3-byte little-endian rate (`0x2058`, `0x1E63`, `0x2562`). Same two rates.
  Every other class or vendor request on EP0 stalls (so do the UAC 2.0 clock requests, which the
  descriptors' shape suggests).
- **`0x0a`** gates nothing by itself, but the dispatcher only runs while configured, so a host never
  sees 0.
- **EEPROM commands.** The running firmware implements `0x02`/`0x03`/`0x16`/`0x17` exactly like the
  bootstrap, so a running box can be reflashed without loading the bootstrap. The enable flag
  (bit `0x21.3`) is set by `0x17` or by a self-enabling `0x02` to address 0, and only cleared by a
  reset. The EEPROM image layout is under "Firmware storage and boot".

## Unsolicited reports (device → host)

Sent from `0x059D` when EP1 IN is free and no command is waiting, highest priority first. Each has
`[1..3] = 00 00 00` and `[4]` = a report number (in place of a tag):

| report | `[4]` | payload | sent when |
|--------|-------|---------|-----------|
| `0x34` | `01` | `[5..10]`: six overload flags (bit *i* of IRAM `0x1D` → byte *i*, 0/1) | the overload byte read from the DSP changes. The 8051 reads it every 80 USB microframes (10 ms) from the SOF interrupt (`0x2226` → `0x1BD0`, DSP read `0x22BD`). Which six signals they are is decided by the DSP (probably the six input channels; unknown) |
| `0x38` | `02` | `[5..7]`: control bytes 0, 1, 2 (the PHONO/LINE switches) | input PD5, PD6 or PD7 changes (polled every main-loop pass, `0x2350`; no debounce) |
| `0x39` | `03` | `[5..8]`: control bytes 8, 14, 20 and 21 | a `0x33` changes byte 8, 14 or 20 (`0x02B1`), or input PD4 changes byte 21 (`0x251A`) |

- **Enable.** All three are sent only while `0x36` has enabled them (bit `0x20.2`). While disabled,
  a pending report is **discarded**, not held (its flag is cleared before the enable is checked), so
  a host should read the state with `0x32` and `0x35` after enabling.
- The enable is cleared at power-up and **every time the box (re)connects to USB** (`0x1B3A`, when
  EP1 is reconfigured: after power-up, `0x1a`/`0x1b`, or VBUS returning). Send `0x36 [5]=01` after
  each enumeration.
- `0x32` cancels a pending `0x38`, and `0x35` a pending `0x34`.
- Rane's kext sends `36 FF FF FF FF 01`: tag `ff ff ff ff`, `[5]=01` (enable).

## Control bytes (`0x32` / `0x33`)

22 bytes. Indices 0–20 live in IRAM `0x08–0x1C` and are what the 8051 sends to the DSP; index 21
is IRAM `0x1F`, a status byte that is never sent to the DSP.

| index | max (`0x2441`) | power-up value | written by `0x33`? | stored in EEPROM? | firmware use |
|-------|------|------|------|------|------|
| 0, 1, 2 — input type Aux / Left / Right (prefPane: 0 = Line, 1 = Phono) | 1 | inputs PD5, PD6, PD7 | 0, 1: no (skipped). 2: accepted, but overwritten from PD7 on the next main-loop pass (and a `0x38` is sent) | no | the three PHONO/LINE switches, **reported only**. Sent to the DSP (DSP addresses 1–3) whenever one changes |
| 3, 9, 15 — phono sensitivity Aux / Left / Right (prefPane: 2.5 + 0.5·n mV) | 15 | EEPROM `0x3FC0`/`0x3FC1`/`0x3FC2` if ≤ 15, else 5 (table `0x242F`/`0x2435`/`0x243B`) | yes | **yes** (`0x102C`, rewritten only when changed) | only passed to the DSP |
| 4, 10, 16 | 127 | `0x60` | yes | no | only passed to the DSP; meaning unknown |
| 5, 11, 17 | 1 | 0 | yes | no | only passed to the DSP; meaning unknown |
| 6, 12, 18 | 127 | `0x60` | yes | no | only passed to the DSP; meaning unknown |
| 7, 13, 19 | 1 | 0 | yes | no | only passed to the DSP; meaning unknown |
| 8, 14, 20 — output routing Aux / Left / Right (prefPane: 1 = USB, 0 = Analog) | 1 | 1 if PD4 is high at power-up; otherwise 1, 0, 0 (table) | yes; a change sends `0x39` | no | the per-deck USB/thru switch (from probing: 1 = USB audio, 0 = analog thru). Only passed to the DSP. When VBUS is lost while the box stays powered, bytes **14 and 20** (not 8) are set to 0 and sent to the DSP (`0x1FC4`) |
| 21 — "extPower" (Sl3Api callback field name) | — | 1 if input PD4 is low, else 0 | no (`0x33` stops at index 20) | no | follows PD4 continuously (`0x251A`); a change sends `0x39`. When 1, the audio side stays powered without a high-speed host and through USB suspend (see below) |

`0x33` rules (`0x023B`): `end = min([5] + [6], 21)`; the value for index *i* is `[7 + (i − [5])]`;
indices 0 and 1 are skipped; a value above the index's maximum is skipped silently; the reply never
says what was skipped. After the loop **all of indices 0–20 are resent to the DSP**, and then
`0x102C` compares bytes 3/9/15 with EEPROM `0x3FC0–0x3FC2` and rewrites any that differ. So
indices 3, 9 and 15 survive a power cycle; **every other control byte, and the sample rate, are
reset at power-up** (`0x2259`). (Earlier probing notes said the control bytes and the rate survive
a power cycle; the firmware does not do that. To check on the hardware.)

The 6-byte blocks 3–8, 9–14 and 15–20 are the **Aux, Left deck and Right deck** blocks (Rane's prefPane,
`readDeviceSettings`; the panel never touches bytes 4–7 of a block, whose meaning stays unknown).
So the firmware's special cases read naturally: with external power (PD4 low = byte 21 "extPower")
the power-up routing is Aux = USB, Left/Right = Analog, and when USB goes away on external power the
Left and Right decks (bytes 14, 20) are switched back to Analog while Aux keeps its setting.
The DSP receives index *i* at DSP address *i* + 1 (block header `00 00 01` for the full block,
`00 00 0F` for index 14 alone, `00 00 15` for index 20 alone; `0x1823`). What the DSP does with
them is in the DSP program in the EEPROM (`0x2800` onwards), which was not disassembled.

### Thru, USB mode and the audio-side enable (PD1)

The firmware never decides thru vs USB per deck itself; it hands bytes 8/14/20 to the DSP. What it
does control is output **PD1** together with a DSP command (`80 00 D1` + word, value 1 or 0):

- PD1 goes high, then DSP `D1` := 1 (`0x1BAA`, `0x237D`), once the box is configured at **high
  speed** or byte 21 is 1, and 10 main-loop passes after a resume (`0x25BD`).
- DSP `D1` := 0 and PD1 low on USB suspend unless byte 21 is 1 (`0x247B`), on `0x1a`/`0x1b` unless
  byte 21 is 1, and on `0x16` / power-up.
- Nothing lowers PD1 when the host merely stops streaming, stops sending `0x37`, closes the device
  or un-configures it (SET_CONFIGURATION 0 only clears IRAM `0x1E`).

Inferred, consistent with the OpenSL3 project's probing: PD1 low = analog thru on every deck
(this is the state with no driver, because macOS leaves the box unconfigured, and when the box is
unpowered); PD1 high = each deck follows its byte 8/14/20. So a host that sets a deck to USB and
then stops streaming leaves that deck silent until it writes 0 there or the box is suspended or
unplugged — the 8051 has no timeout that would undo it.

## Audio streaming

- **Format** (descriptor `0x112E`, read): UAC 2.0-shaped descriptors with vendor class codes.
  Format type I, **3-byte subslots, 24-bit resolution, 6 channels → 18-byte frames**, both directions.
  `wMaxPacketSize` 126 = 7 frames. EP `0x06` OUT: isochronous, asynchronous (`0x05`); EP `0x82` IN:
  isochronous, asynchronous, implicit feedback (`0x25`). Channel names in the descriptor are only
  "CH1 Out"…"CH6 Out" and "CH1 In"…"CH6 In" (strings 5–10, 11–16). Capture AS interface links to
  terminal 3 (the line input) instead of 4 — a descriptor bug, harmless.
- **Starting:** selecting alt 1 is all the firmware needs. IF1 alt 1 → EP6 `0x9A` (ISO OUT, 512,
  double-buffered), `AUTOOUT`, FIFO reset; IF2 alt 1 → EP2 `0xDA` (ISO IN, 512, double), one packet
  per microframe, FIFO reset, then the 8051 **commits two IN packets of 90 and 108 bytes itself**
  (5 and 6 frames of stale buffer contents: the "first two or three packets" of stale data seen when
  probing the box). After that, IN packets are committed by the external FIFO master, which therefore
  decides the 5/6-frame pattern; the 8051 never touches sample data. Both are refused unless
  configured at high speed. Alt 0 un-configures the endpoint.
- Audio itself also needs the DSP running and PD1 high, which the firmware does on its own after a
  high-speed SET_CONFIGURATION (above); no vendor command is needed. Channel order and jack mapping
  are decided by the DSP/FIFO side and cannot be read from the 8051 code; Rane's prefPane labels the
  channels **1/2 Aux, 3/4 Left deck, 5/6 Right deck** (the order of the control blocks too), so that is
  the expected order (not verified with signals). Whether any byte is constant is unknown from the
  firmware, and Rane's kext checks none. The DSP56300 is a 24-bit machine, so there is no reason to expect a
  constant padding byte (the 3-byte subslot leaves no room for one, unlike the SL 2's 4-byte
  slots); treat "detect arrival via a zero byte" as unavailable on the SL3.

## Firmware storage and boot

- **The firmware lives in the box's I2C EEPROM** (FX2 address `0x51`); the FX2 boots it at every
  power-up (boot byte `C2`). Nothing is loaded by the host in normal use.
- **EEPROM layout** (the 0x3900-byte "final" image minus Rane's 0x40-byte header, written from
  EEPROM address 0):

  | EEPROM | contents |
  |--------|----------|
  | `0x0000` | 8-byte FX2 header `C0 C5 1C 01 00 00 00 01` in the image (`C0`, VID `1CC5`, PID `0001`, DID `0000`, config `01`); byte 0 becomes `C2` when `0x16` finalises |
  | `0x0008–0x261B` | 8051 code records (`[len BE][addr BE][data]`, 1023-byte chunks) for `0x0000–0x25EB`, end record `80 01 E6 00 00` (CPUCS := 0) |
  | `0x2800–…` | DSP boot stream, stage 1: word count `0x0001D6`, then 24-bit words; the 8051 streams it to the DSP and expects the DSP to answer `64 65 66` ("def") |
  | `0x2E00–0x387F` | DSP stage 2 (starts `00 02 D2 …`), streamed after the "def" handshake (`0x0D78`); its block structure was not decoded |
  | `0x3FC0–0x3FC2` | settings: control bytes 3, 9, 15 (outside the image, so reflashing keeps them) |

  Rane's 0x40-byte file header: `"Copyright 2009 Rane Corporation"`, then `01 1C C5 00 01 00 00 02
  32` (VID, PID, version 2.50) at `0x20`, and `38 C0` (payload length 0x38C0) + a 32-bit check value
  at `0x3A` (the check algorithm was not traced).
- **A box with a `C0` boot byte** (after `0x17`, or a failed update) enumerates as the FX2's built-in
  default device, using the VID/PID/DID from the EEPROM header: **`1CC5:0001`, bcdDevice `0x0000`**,
  with Cypress's default descriptors (vendor class, no string descriptors, one interface with
  alternate settings and bulk/iso endpoints) and the FX2 `0xA0` RAM-load vendor request. So
  VID/PID/bcdDevice are the same as the running firmware's; the absence of strings and of the
  4-interface configuration is the difference (inferred from FX2 behaviour; not observed).
- **The bootstrap** is loaded into RAM over `0xA0` by the host. It re-enumerates with **exactly the
  same descriptors as the running firmware** (`1CC5:0001`, bcdDevice 0, the same strings including
  serial `"SL3.01.00"`, the same 4-interface configuration; boot `0x0D00`, `0x0D2E`), keeps the DSP in
  reset (PD2 low), and accepts the same EP1 commands minus `0x1a`/`0x1b` and the `0x39` report.
  The only reliable way to tell it from the running firmware is **`0x01`: `02 19` = bootstrap,
  `02 32` = running v2.50**. `0x03` at address 0 tells whether the EEPROM is currently bootable
  (`C2`) or not (`C0`).
- **Update sequence** (from the firmware's side; same as the SL 2): `0x17` (or a first `0x02` to
  address 0 with `C0`), `0x02` for each 32-byte block from address 0, compare the read-back in each
  reply, then `0x16` to write `C2` and restart.

## Kext and Sl3Api behaviour

From `Sl3Driver.10.9.kext`, `Sl3Api`, the prefPane and `Sl3SettingsService` (addresses are those
x86_64 binaries'). Read unless marked. Sl3Api's exports in full are in `docs/SL3-AUDIO-ENGINE.md`,
"Sl3Api".

- **Framing** (`DoHidRequest` 0x1d14): `[0]` opcode, `[1..4]` a counter used as tag (little-endian),
  `[5..]` up to 59 argument bytes, written asynchronously to EP `0x01`. EP `0x81` is read continuously
  (`CheckHidRead` 0x197a); every report is copied to every open user client; the kext never parses
  replies. `SendHidRequestInternal` (0x5952) waits up to 5 s for a reply with the same tag and
  `reply[0] == opcode`.
- **At start** (`InitHid` 0x1370): `36 FF FF FF FF 01` once (enable unsolicited reports), then
  `ExternalSetSampleRate(48000)` → `31 <tag> BB 80`. Rane's default rate is 48 kHz, set by the kext.
- **Rate changes** (`performFormatChange` 0x4f8a, user-client selector 3) send `0x31`. **Wake**
  (`performPowerStateChange` 0x6124) resends `0x31` with the current rate, but not `0x36`.
- **Nothing is sent at stream start, stream stop, close, terminate or sleep.** The kext never touches
  control bytes 8/14/20; routing is set only by the prefPane or Serato through Sl3Api. Both
  streaming interfaces are put in alt 1 at init and never set back to alt 0.
- **No `0x37` in the kext.** `DoTimerAction` (0x1c8e) only estimates the USB frame clock. `0x37` is sent
  by Sl3Api's `sl3_driver_timer` whenever its caller (Serato) calls it; that period was not traced.
- **User client** (`sMethods` 0xaeb0): 0 Open, 1 Close, 2 HID send (60-byte struct → opcode + bytes
  5..63, no opcode filtering), 3 SetParameter (rate), 4 IsC0Device, 5 VendorId, 6 ProductId,
  7 DriverVersion, 8 GetStatus, 9 EP0 control request (C0 mode only), 10/11 set/get buffer ms (1..50),
  12 read queued HID reports.
- **Sl3Api → opcodes:** `sl3_get_firmware_version` `0x01` (`[5]`,`[6]`); `sl3_get_status` `0x0a`;
  `sl3_get_parameter(0)` `0x30`; `sl3_get_audio_controls` `0x32`; `sl3_set_audio_controls` `0x33`;
  `sl3_get_overload_status` `0x35`; `sl3_driver_timer` `0x37`; `sl3_set_alt_product_id` `0x1a`.
  `sl3_get_usb_port_status` does no USB I/O (it is the driver-connected flag). There is no
  serial-number function. Unsolicited reports go to callbacks: `0x34` overload (6 bytes), `0x38`
  {preampA, preampB, preampC}, `0x39` {aux, leftDeck, rightDeck, extPower}.
- **Streaming** (`SetAvailableFormats` 0x6410, `DoInputCopy` 0x3f2c, `OutPrepMicroframe` 0x30c4):
  6 channels, signed 24-bit little-endian in 3 bytes (18-byte frames), 44100 and 48000 Hz, one packet
  per microframe. An input packet of 90..125 bytes (44.1k) or 90..143 bytes (48k) is accepted,
  frames = length / 18, and the next output packet carries the same number of frames (implicit
  feedback). No byte of a frame is checked for a fixed value. No EP0 class or vendor requests in
  normal operation.
- **Matching and boot mode:** one personality, `1CC5:0001` bcdDevice 0. There is no descriptor-based
  bootloader check: if the vendor interface with EP `0x81`/`0x01` is missing, the kext enters
  "C0 mode", creates no audio engine and allows EP0 requests (selector 9). A box on FX2 default
  descriptors falls into that path (inferred). The kext does not match PID `0x0003`, so after `0x1a`
  Rane's driver no longer sees the box.
- **Update** (`UpdateBootstrapFirmware` 0x375e, `UpdateFinalFirmware` 0x3450): bootstrap over EP0
  `0x40/0xA0` (CPUCS `0xE600` := 01, 32-byte chunks from address 0, read back with `0xC0/0xA0`,
  CPUCS := 00); Sl3Api then reopens the user client (up to 30 tries). Final image: `0x17`, then `0x02`
  per 32-byte chunk (big-endian address; the reply must echo address and data, except that chunk 0's
  byte 3, the PID low byte, is accepted back as `03` when `01` was sent — why is unknown, since this
  firmware forces `01` there), then `0x16`. The prefPane offers the update when the embedded version
  (2.50) is greater than the `0x01` reply. Rane's header check value is a big-endian CRC32.
- **Settings service** persists only the buffer size and a first-run latency flag, never control
  bytes.

## Answers to the questions this analysis set out with

Confidence: **high** = read directly from code; **medium** = read, but depends on an inference
about hardware or on the separate kext analysis; **low** = inference.

1. **Command table** — above (high). Opcodes: `00 01 02 03 06 0a 16 17 1a 1b 30 31 32 33 35 36 37`;
   everything else → `0xFF`. ⚠ EEPROM writes: `0x02`, `0x16`, `0x17`, and `0x33` (settings bytes
   `0x3FC0–2` only, on change). ⚠ Non-bootable: `0x17` (and any `0x02` to address 0). ⚠ Bootable +
   restart: `0x16` (no enable check). ⚠ Re-enumerate: `0x1a` (PID `0003`), `0x1b` (PID `0001`).
   Version is **`0x01`**, not `0x10`: `[5]=02 [6]=32` (v2.50), `[7..10]` build stamp (high).
   There is **no serial command** (`0x04` does not exist; the serial string is the constant
   "SL3.01.00") and **no port-status command**. USB speed/state is **`0x0a`** `[5]` = 0/1/2. **`0x03`
   is an EEPROM read**, not device info: at address 0 byte `[7]` is the boot byte, and Rane's "C0
   device" is a box whose boot byte is `C0`. **`0x17` is "mark non-bootable and enable writes"** —
   never send it (high).
2. **Unsolicited reports** — `0x34` (overload, 6 flags, polled from the DSP every 10 ms), `0x38`
   (PHONO/LINE switches = control bytes 0–2), `0x39` (routing bytes 8/14/20 + extPower byte 21); no
   others (high). Layout `[1..3]=0`, `[4]` = 1/2/3. Enabled by `0x36` with `[5]` ≠ 0, disabled by
   `[5]` = 0; the other bytes (Rane's kext sends `ff ff ff ff`) are the tag and ignored.
   Reports raised while disabled are dropped; the enable resets on every (re)connection (high).
3. **`0x37` heartbeat** — **no watchdog** in the 8051: the handler and its XXTEA-like routine touch only
   scratch RAM, there is no timer interrupt, and nothing changes the audio state on a timeout (high).
   The DSP cannot know about `0x37` either, since the 8051 sends it nothing for it (high). Reply = 8
   bytes computed from the challenge (key not extracted); nothing from the host is required (high).
   Rane's kext never sends it; Sl3Api sends it only when Serato calls `sl3_driver_timer` (medium).
   The "silent when the heartbeat stops" observation is explained by the routing bytes staying at USB
   while no audio is streamed (medium).
4. **Control bytes** — 0–2: PHONO/LINE input type for Aux/Left/Right, physical switches PD5–PD7,
   reported only (high; names medium). 3/9/15: phono sensitivity 0–15 per block, the **only** bytes
   stored in EEPROM (high; name medium). 4/6 (0–127, default 96) and 5/7 (0/1) per block: passed to the
   DSP only, unused by Rane's panel, meaning **unknown**. 8/14/20: Aux/Left/Right routing, 1 = USB,
   0 = analog (medium). Blocks: 3–8 Aux, 9–14 Left, 15–20 Right (medium). 21: input PD4, "extPower",
   read-only (high for behaviour, medium for name). All except 3/9/15, and the sample rate, reset at
   power-up — contradicting earlier probing notes (high).
5. **Streaming** — 24-bit in 3-byte little-endian subslots, 6 channels, 18-byte frames, both
   directions (high); 5/6 frames per microframe at 44.1 kHz; channel pairs 1/2 Aux, 3/4 Left deck,
   5/6 Right deck (medium, from Rane's labels). No constant byte can be relied on: the slot has no
   padding and nothing in firmware or kext suggests one (medium; check a capture). Nothing besides
   alt 1 is needed from the firmware's side; audio also requires a high-speed SET_CONFIGURATION, which
   powers the audio side (PD1) and enables the DSP (high). Rane's kext sets 48 kHz with `0x31` at start;
   the box itself starts at 44.1 kHz (high).
6. **Firmware storage and boot** — the firmware (8051 code + DSP program) is in the box's I2C EEPROM
   and boots by itself (high). The bootstrap is a RAM-loaded EEPROM writer for boxes whose EEPROM is
   marked `C0` or corrupt (high). A `C0` box enumerates as the FX2 default device with `1CC5:0001`,
   bcdDevice `0000` and no strings (medium: FX2 behaviour plus the header bytes). The running bootstrap
   enumerates exactly like the running firmware (high); `0x01` (`02 19` vs `02 32`) is the only way to
   tell them apart. Rane's kext tells "C0 mode" by the missing vendor HID interface, not by
   descriptor values (medium).
7. **Kext behaviour** — at start `36 … 01` and `31 BB 80` (48 kHz); `0x31` again on rate change and on
   wake; nothing at stream start/stop/close/sleep; no periodic traffic (no `0x37`); never touches the
   thru/USB bytes (medium; from the kext analysis).

### Firmware 2.31

A box tested by this project runs firmware 2.31 (`0x01` answers `02 1F`, build stamp `4D 12 8A 13`),
dumped from its EEPROM with `sl3dump` and disassembled the same way. It is the same as 2.50 in: the opcode
set and dispatch; the EEPROM gating of `0x02`/`0x17`; `0x31`'s two rates and the UAC 1.0 endpoint rate
request; the control bytes' maxima and defaults; which bytes are saved (3/9/15 at `0x3FC0–2`); the alt-1
streaming setup; `0x36` cleared at every enumeration; the `0x37` routine; **no watchdog** (the timer
interrupts are unused, the SOF interrupt only schedules the overload poll, and nothing reacts to `0x37`
traffic stopping). It differs in:

- **No `0x39` report.** Only `0x34` and `0x38` exist, so a change of output source is not confirmed
  (observed: no report after `0x33` to bytes 8/14/20, with reports enabled).
- **The DSP boot sets the routing and the rate.** When the DSP has booted (after a high-speed configuration,
  and after every resume from USB suspend), bytes 8/14/20 are forced to 1 (USB) and the rate to 44100. A host
  must set thru and the rate again afterwards (the driver's settle check does). Observed after a Mac sleep:
  every deck on USB and the rate at 44100 on wake.
- Byte 21 is computed from PD4 when `0x32` is read rather than stored; there is no DSP "D1" command; bytes
  14/20 are also cleared on suspend with external power.
- The DSP program's first stage (`0x2800–0x2E01`) is the same as 2.50's; the second stage is a different build.

Measured on that box: the rate is 48000 after the driver sets it and stays there through re-enumeration;
control bytes 4/6 of each block read `0x60`, 5/7 read 0; the phono sensitivity byte can be set and is saved.
The `0x38` report follows each deck's switch, without debouncing: a switch can read PHONO–LINE–PHONO within
half a second as it moves, and flipping one switch made its neighbour (the deck before it: Aux for Left,
Left for Right) read PHONO for about 0.2 s; every reading settled to the switch's position.

The same box updated to 2.50 with `sl3flash`: `0x01` answers `02 32`, and a client's change of a deck's
output source is confirmed with a `0x39` report (six reports for six changes in `sl3apitest`).

### Corrections to earlier notes on this box

The OpenSL3 project's protocol notes (this repository's `docs/PROTOCOL.md` until this document
replaced it) were worked out by probing. Where the firmware says otherwise:

- `0x17` is not a version query; it makes the box unbootable (⚠). `0x03` is an EEPROM read.
- The rate and the control bytes are **not** kept over a power cycle, except bytes 3/9/15.
- Index 21 is not set by host writes (`0x33` cannot reach it); it follows input PD4 (external power).
- Index 2 cannot be set by the host; indices 0–2 are the three PHONO/LINE switches.
- `0x34`/`0x38`/`0x39` layouts are now known (above); there is no USB-port-status report.
- The box needs no `0x37` heartbeat to play USB audio.
