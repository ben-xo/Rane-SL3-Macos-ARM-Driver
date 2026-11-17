# SL 3 audio engine: low-latency streaming design, measurements and bug catalogue

This document describes how the SL 3 HAL plug-in (`plugin/SL3Device.m`) moves audio between CoreAudio and the
box, and how it handles the box coming and going and talking to clients (Serato, Rane's control panel). The
driver is the SL 2 driver's engine (pepeleedj/Rane-SL2-Macos-ARM-Driver, `docs/SL2-AUDIO-ENGINE.md` there)
with the SL 3's hardware in its place: the design, the reasoning and the SL 2's bug catalogue apply as they
stand, and this document gives the SL 3's differences and its own catalogue. The SL 3's protocol is in
`docs/SL3-COMMANDS.md`.

> **Fixing a playback or capture bug? Start here.**
> 1. Build and install a debug driver: `make install DEBUG=1`, and the test tools: `make latency`.
> 2. Connect a loopback cable from Left Deck Out L to Left Deck In L (channel 3), with the Left deck's
>    LINE/PHONO switch on **LINE** (`tools/latency/README.md`).
> 3. Run `tools/latency/restartcheck.sh` and `tools/latency/dptest.sh 60`. Both print PASS or FAIL. The driver's
>    counters should read as in [Testing](#testing).
> 4. Reproduce stalls and errors on demand with `tools/latency/bin/sl3dbg` (stall the USB queue, error capture
>    packets), and read the driver's log with `tools/latency/logq.sh`.
> 5. The [bug catalogue](#bug-catalogue) gives each past bug's symptom and regression test; the SL 2's
>    catalogue covers the shared engine.

## Results

Measured on an SL 3 running firmware 2.31, through one USB hub, with a loopback cable from Left Deck Out L
to Left Deck In L (channel 3, line level), debug build, `make hwtest ARGS="--loopback"` (2026-11-17):

| SL 3 | IO buffer | Unreported latency | Est. DVS round trip | Glitches |
|---|---|---|---|---|
| 48 kHz | 32 / 45 / **48** / 64 frames | 3.0 ms | 7.8 / 8.4 / **8.5** / 9.1 ms | — |
| 48 kHz | 128 / 256 / 512 frames | 3.0 ms | 11.8 / 17.2 / 27.8 ms | none in 30 s idle and 30 s with every core busy (`dptest.sh`) |
| 44.1 kHz | 32 / 45 / 48 / 64 frames | 3.1 ms | 8.1 / 8.7 / 8.8 / 9.5 ms | — |
| 44.1 kHz | 128 / 256 / 512 frames | 3.1 ms | 12.4 / 18.3 / 29.9 ms | none in a 10 s check |

48 frames at 48 kHz is Serato's IO buffer for the SL 3, so Serato DJ Pro gets an **8.5 ms** DVS round trip.
The early read's least margin was 1.17 ms at the 1.5 ms input safety offset, through a 20 ms completion
stall. Glitches were seen in two 30 s runs out of about twenty (18 and 101, residuals 0.01–0.19 against a
0.4 tone) while other work ran on the Mac, with every driver counter clean (no late writes, nothing
unscheduled, sent − captured within 2, no early-read differences); they couldn't be reproduced with
every core busy, during a full rebuild, or after click tests, and a later 8-minute hwtest run was clean.
Their cause is open; nothing the driver measures moved.

The box runs with no `0x37` heartbeat: 30 s glitch tests at full level, decks on USB audio throughout.

For comparison, the same engine on the SL 2 (loopback Left Deck Out L to In L, line level, 44.1 kHz unless
noted):

- **Unreported latency** is the delay beyond what the HAL's timestamps account for, found by playing clicks
  and locating them in the captured input (`tools/latency/rtlat.c`).
- **Estimated DVS round trip** adds the HAL's own per-cycle gap (safety offsets and IO buffers). It
  approximates input jack → application → output jack, for an application that responds in the same IO cycle.

| SL 2 driver | IO buffer | Unreported latency | Est. DVS round trip | Glitches under load |
|---|---|---|---|---|
| Baseline, before the latency work | 128 frames | 76 ms | ~105 ms | — |
| Deep schedule + early capture read, measured | 128 frames | 2.9 ms | **12.2 ms** | none in 10 min, idle and all cores loaded |
| Deep schedule + early capture read, measured | **64 frames** | 2.9 ms | **9.3 ms** | none in 150 s with six x264 encodes running |
| Deep schedule + early capture read, 48 kHz, release build | 64 / 128 frames | 2.8 ms | **8.9 / 11.6 ms** | none in a 30 s check, idle |
| Deep schedule + early capture read, release build: Serato's 1 ms | **45 frames** | 2.8 ms | **8.3 ms** | none in 60 s idle and 150 s with six x264 encodes |

The two boxes come out within a few tenths of a millisecond of each other: the SL 3's own part of the round
trip (its FIFOs, DSP and converters) is 73–74 frames at either rate.

**Serato's "USB buffer size" is the CoreAudio IO buffer size.** Serato DJ Pro (2.5.5, from its code) turns
the setting into frames, rounded to the device's alignment (Serato's description of the SL 3 gives 48 frames,
at 48 kHz, the only rate it uses for the SL 3), and sets `kAudioDevicePropertyBufferFrameSize` through
PortAudio, restarting its stream. It tells neither Sl3Api nor the box. So it is the "IO buffer" in the tables
here, which counts twice in the round trip; the input safety offset (counted once) is separate from it.

## Background

**The HAL timeline.**
- A HAL plug-in does not push audio on its own schedule. The HAL drives IO and keeps a sample timeline.
- The plug-in's `GetZeroTimeStamp` tells the HAL which host time corresponds to which sample, in periods
  (16384 samples here; `AudioServerPlugIn.h` requires at least 10923).
- The HAL expects successive answers to lie on a straight line. If one falls off it, the HAL logs
  `clockResetReason: TimeStampOutOfLine` and resets its clock, which is an audible gap.
- WriteMix gives the driver output audio for timeline positions; ReadInput asks for input at timeline positions.

**USB.**
- The SL 3 is a USB 2.0 high-speed device with isochronous endpoints: OUT 0x06 (asynchronous) and IN 0x82
  (implicit feedback). Both have `wMaxPacketSize` 126, which is 7 frames of 18 bytes (6 channels of packed
  24-bit samples) per 125 µs microframe; at 44.1 kHz the box sends 5 or 6 frames a microframe, at 48 kHz 6.
  On a full-speed (USB 1.1) link the box offers only its HID interface, and there is no audio.
- The driver uses `IOUSBHostPipe` transaction-list transfers of 8 packets, which is 1 ms each.
- *Implicit feedback* means the box tells the host how many frames to send by how many it sends: OUT
  packet sizes should follow IN packet sizes.

**Completion latency.**
- USB completions are delivered on a dispatch queue in the driver's process. The kernel can hold them before
  any thread is woken: stalls of 5–11 ms about once a minute were measured here, and other projects report
  up to 30 ms under load.
- Real-time scheduling cannot be obtained for those threads from user space. `thread_policy_set` is refused
  on GCD threads with `KERN_POLICY_STATIC`, and joining a CoreAudio workgroup is refused for non-real-time
  threads. Even real-time threads see the same delays, because the delay comes before wake-up.
- Any design that must react to a completion within a few ms will drop out under some conditions.

## Design

### 1. Timeline clock (`clk_*`)

- **The timeline is a line:** sample `g_clk_sample` at host time `g_clk_host`, advancing one sample every
  `g_clk_tpf` host ticks.
  - It starts when streaming starts and never jumps.
  - It is published under a sequence lock, because `GetZeroTimeStamp` reads it on the HAL's IO thread.
    Readers on the IO thread are bounded: after 64 tries they use the last good copy rather than spin.
- **`clk_track` keeps it on the box's clock.** Every 2048 captured frames it re-anchors the line where it is,
  so the line stays continuous. It sets the rate to the box's measured average plus a correction that pulls
  the line onto the box's real captured-frame count over 2 s. (On the SL 2, which runs about −105 ppm
  against nominal 44.1 kHz, the tracker holds the phase error under 2 frames; the SL 3's to be measured.)
- **Times are bus times.**
  - A capture transfer's frame number gives its time on the bus, through a (microframe, host time)
    reference from `currentMicroframeWithTime:`. This is refreshed at most every 0.5 ms and read through a
    bounded sequence lock (`dp_ref_*`; `usb_frame_time` and `dp_frame_at` convert both ways).
  - Completion `timeStamp`s are not used. They record when the stack processed the transfer, which can be
    many ms after the bus.
  - The `frameNumberWithTime:` and microframe counters were checked to agree.

### 2. Capture

- **Placement on the timeline:**
  - The first captured frame goes at the timeline position matching its bus time (`g_cap_base`). Every
    later frame follows it contiguously in the input ring.
  - Capture publishes how far it has written (`g_cap_head`). ReadInput reads the ring at the HAL's input
    sample time, and returns silence for any position capture has not written yet, or wrote so long ago that
    the ring may have wrapped over it. A late capture therefore costs a short gap, never old audio.
- **Frames the host doesn't receive are filled with silence.** The box clocks a frame of audio whether or not
  the host gets it. An errored packet, or USB frames with no capture request queued (see below), are filled
  with silence at the box's measured rate (carrying the fraction of a frame to the next fill) and counted as
  captured. The ring, the clock tracker and the playback steering then all count what the box clocked.
- **Capture survives a long completion stall.** Each of the 64 capture transfers is re-queued from its own
  completion. After a stall longer than 64 ms, the next frame has passed: the request is re-anchored
  `DP_START_LEAD` frames ahead of the bus, and the frames skipped are filled when the next completion
  arrives (logged as "Capture: N ms not captured").
- **ReadInput doesn't wait for completions (the early read).**
  - Completions are delivered late: capture handlers ran at most 1.5 ms after their frame's bus start
    99.99% of the time, but up to 7.6 ms idle, and 12–18 ms with the Mac swapping. An input that
    waited for them would need a safety offset that long, and a longer stall would still leave a gap.
  - The data itself is on time. The controller writes each packet into the transfer's buffer during the
    packet's own microframe: measured, every packet was in memory before its microframe ended, with
    heap and `ioDataWithCapacity:` buffers alike.
  - So ReadInput, on the HAL's real-time IO thread, reads the packets that have arrived since the last
    completion out of the queued buffers and places them in the ring itself (`cap_read_early`), once
    their microframe has been over for one more microframe (a packet can be caught part-written during
    its own).
  - A packet's frame count is only reported with its completion, so each buffer is filled with a mark
    byte (`0xA5`) before it is queued, and a frame slot whose 18 bytes still all read `0xA5` has not been
    written. The frames before the first such slot are the ones that arrived; the last of them counts only
    once its last sample no longer reads as the mark, so a frame caught part-written is left to the
    completion. (The SL 2 marks with `0xFF` and counts frames by the pad byte of each sample, which is
    always 0 there; the SL 3's samples are packed in 3 bytes, with no pad. A real frame equal to the mark
    would need all six samples at `0xA5A5A5`.) A packet with no frames is left to the completion (missing
    or errored), as is one the kernel has already marked errored in the transaction list, which it updates
    in our array 0–2 ms after the microframe.
  - The early reader starts from the completions' progress (the next USB frame, and the timeline position
    of its first frame) and places frames where the completion will. The completion stays in charge: it
    writes the same frames again and keeps the clock tracking, steering, meters and silence fills. If it
    placed frames differently, the early reader's position for that frame no longer matches and it
    starts again from the completion's.
  - A buffer is tagged with its USB frame while queued and 0 while it is refilled. The early reader checks
    the tag before and after each packet, so a refilled buffer never reaches the ring.
- **The input safety offset is 1.5 ms by default.** Measured on the SL 3 (firmware 2.31): the least margin was
  1.17 ms idle and 0.75 ms over long runs, through a 20 ms completion stall with no gap. The SL 2's figures:
  - On the SL 2, with the early read, the least margin (how far ahead of the read the captured frames
    reached) was the offset less about 0.35 ms idle, and less 0.75–0.9 ms under load. At 1 ms the margin
    under load fell to 0.23 ms; at 1.5 ms it stayed 0.6–0.73 ms (5 min idle, 5 min all cores busy, six
    x264 encodes). The margin depends on the Mac's USB controller and on the settle time, not on the box,
    so the same figure is expected on the SL 3; `DBG early read`'s least margin will show it.
  - It is a setting (`sl3i`, 0.5–20 ms; the SL 3 Control Panel and `sl3panel safety <ms>` set it), kept in
    the plug-in's storage, which the HAL keeps across restarts.
  - The HAL only reads safety offsets when it sets the device up, so the setting changes only with nothing
    streaming. The driver then takes the device out of the device list for half a second, which sets it up
    again (`relist_device`). The value the property reports changes only at that moment, so it is always
    the value the HAL is using.
- **Where the early read doesn't work, the driver says so.**
  - Each stream judges the early read once it has a second of capture and ReadInput has asked for half a
    second of it (`early_read_judge`; an app that only plays doesn't read input, and leaves it unjudged).
    It works if it placed frames and the completions found under 1% of them different. This needs no
    signal at the inputs: silence is all zero bytes, distinct from the marks.
  - If it doesn't work (a USB controller that copies the data in only at completion, or a box that writes
    its packets differently from what the marks expect), the driver logs it and reports it in the status,
    and the SL 3 Control Panel asks for an
    input safety offset of 8 ms, which covers completion delivery. The driver doesn't change the setting by
    itself: applying it takes the device out of the device list for a moment, which apps holding it idle
    (or the system's default output) would see as the device going away. Changing the setting has the next
    stream judge afresh. `sl3dbg noearly 1` *(debug)* switches the early reader off to test this.
- **Input health is reported.** The status (`sl3s`) carries the offset in use, the early read's judgement,
  the IO cycles in which input wasn't captured in time (ReadInput returned silence) since the device was set
  up (the box connected, or the offset changed: dropouts at another offset say nothing about this one),
  and how many USB hubs the box is behind (its ancestors in the I/O Registry that are USB
  devices). The SL 3 Control Panel warns about the first three and shows the hub count. A high-speed hub
  adds no latency that matters here (it forwards packets within microseconds, inside the 125 us
  microframe schedule); the SL 2's figures were measured through two.

### 3. Playback: deep schedule with late writes (`dp_*`)

**The approach.**
- 128 transfers of 1 ms are kept queued ahead, in buffers from `-[IOUSBHostObject ioDataWithCapacity:]`,
  zero-filled when submitted.
- WriteMix writes each sample straight into the queued transfer that will carry it, while that transfer is
  still at least 1 USB frame (1 ms, `DP_WRITE_GUARD_FRAMES`) from starting.
- Completions only queue new transfers at the far end of the schedule. So a stall in completion delivery does
  not interrupt the audio unless it outlasts the queue: about 120 ms at small IO buffers (the 128 ms queued,
  less how far ahead the HAL writes, about two IO buffers plus the safety offset).

**Why late writes work.**
- The controller reads a transfer's buffer when the transfer starts, not when it is submitted. Apple DTS
  describes this as the intended use of the isochronous API (developer forums thread 853369), while noting
  that exactly when a controller reads the buffer is implementation-specific.
- It was verified on the SL 2: 59,473 transfers were written 1–2 frames before their start, with 0 missed,
  and the tone written into them came through continuously. It is the Mac's controller that reads the
  buffer, so the same holds for the SL 3; `dptest.sh`'s `late` and glitch counts confirm it.

**The schedule ring.**
- `g_dp_sched[512]` is indexed by USB frame. For each queued frame it holds the timeline position of its
  first sample, each packet's sample offset, its cumulative sent count and its buffer.
- An entry is published, with its frame number as a sequence-lock tag, only after its enqueue succeeds.
- WriteMix finds a sample's frame by estimating from the **newest published frame** (`g_dp_newest`) and
  stepping. It takes no locks and makes no IOKit calls.

**Timing budget.**
- A schedule's first frame (`dp_anchor`) carries the timeline position `DP_OUT_LATENCY_MS` (1.5 ms) before
  that frame's start. Every sample then plays 1.5 ms after its timeline position.
- The HAL writes each sample `DP_OUT_SAFETY_MS` (2 ms) ahead of "now". Together these 3.5 ms cover the up-to-
  1 ms span of positions within a frame plus the 1 ms guard, leaving 1.5 ms of margin for a late IO thread.

**Packet sizes.**
- Sizes are fixed when a transfer is queued, about 128 ms before it plays, so they cannot be copied from
  capture packets.
- They are predicted from the clock tracker's rate and steered so that the cumulative frames sent through
  each USB frame equal the cumulative frames captured through it (`dp_track_capture`, over about 1 s). The
  captured count includes silence-filled frames (see Capture).
- The SL 2 accepts predicted sizes, and the sent − captured difference stays within ±2 frames. Rane's SL 3
  kext copied each capture packet's size to the next OUT packet; whether the SL 3 accepts predicted sizes
  as the SL 2 does is to be confirmed (`dptest.sh`, sent − captured).

**Refusals and recovery.**
- A refused enqueue publishes nothing. Its timeline positions move to the next frame, so the audio stays
  continuous, and it is not counted as sent, so the steering makes up the frames the box missed.
- A slot is never lost: after 4 refusals it is retried 2 ms later.
- If the schedule runs dry, it re-anchors 8 frames ahead of the bus (`DP_START_LEAD`). That only happens
  when it reaches less than 4 frames ahead (`DP_DRY_LEAD`), after a stall of nearly the schedule's length.

**Several clients.**
- When a second application plays to the device, the HAL calls WriteMix from more than one IO thread in
  turn. The calls never overlap and never repeat a timeline position: each carries the full mix for its
  stretch.
- So WriteMix overwrites; it does not mix. This was measured on the SL 2 with Serato and a second client
  playing together, and both were heard.

**Stream start and stop.**
- Each stream has a generation number (`g_stream_gen`), bumped when it starts and when it stops. Every USB
  completion and retry carries the generation it was queued in and does nothing once it has moved on, so
  work left over from a stopped stream never touches the next one.
- `dp_stop` switches the schedule off and waits for any WriteMix still inside `dp_write`.
- `usb_release_audio` aborts the pipes, then frees the buffers and pipes **on the USB queue**
  (`dispatch_sync`), so no completion handler is still using them, then puts the interfaces back to
  alternate setting 0 and destroys them. The buffers keep the playback interface claimed until they are
  freed. Every failure path of `usb_open_all` uses the same function.

### 4. Reported properties

| Property | Value |
|---|---|
| Output device latency | 1.5 ms |
| Output safety offset | 2 ms |
| Input device latency | 44 frames (measured on the SL 3) |
| Input safety offset | 1.5 ms (the default setting; 8 ms recommended where the early read doesn't work) |
| Output stream latency | 32 frames |
| Input stream latency | 0 |
| Zero-timestamp period | 16384 frames |

The output latency and safety offsets come from the design (the 1 ms transfers and write guard). The input
device latency is the SL 3's own, from `rtlat`: the box adds 73–74 frames beyond the output latency, so with
the output stream's 32 frames the input device reports 44. The total, 142 frames at 44.1 kHz and 148 at
48 kHz, is a few frames over the measured 138–139 and 143–146, on the safe side.

### 4a. Output volume (`vol_*`)

The SL 3 has no known volume control of its own: Rane's software sets no level, and among the control bytes
the box passes to its DSP none is known to be a level (bytes 4 and 6 of each deck's block, 0–127, power-up
value 96, are unidentified; worth testing). So, as on the SL 2, the driver scales the samples itself: a
master **Output Volume** and **Output Mute**, which the menu-bar slider and the volume keys use, and a
**volume for each of the six output channels**, shown per channel in Audio MIDI Setup. All run from −64 to
0 dB, with the bottom silent, on CoreAudio's standard volume curve (`docs/SL2-AUDIO-ENGINE.md`, §4a, in the
SL 2 driver, gives the curve). A channel's gain is the master's times its own; without the master the volume
keys would move only channels 1–2, the Aux deck.

- **Where:** in `ProcessMix`, on the mix of all clients, just before WriteMix. It adds no buffering and moves
  no timing. At 0 dB, unmuted, no sample is touched. A change of level ramps over 5 ms for the full range.
- **Every client follows it, Serato included.** The HAL saves the volume and mute per device and sets them
  again when the device reappears.

### 5. Sample-rate changes

- Rates change through `RequestDeviceConfigurationChange` / `PerformDeviceConfigurationChange`.
- `0x31` from a client over `sl3h` to the other supported rate is routed the same way: the box only gets it
  from Perform, so the HAL's rate and the box's change together.
- The zero-timestamp seed is bumped, so the HAL resyncs.
- **48 kHz by default**, as Rane's driver set it, and the rate Serato DJ Pro 2.5.5's description of the SL 3
  asks for. The chosen rate is kept in the plug-in's storage. The box powers up at 44.1 kHz whatever was set
  before, so the driver sets the rate at every connect.

### 6. Connect, disconnect and status

- **The device is listed only while a box is attached.** A box with no firmware running keeps the device
  listed, so clients can read `boot_mode` from the status.
- **A box with no firmware** (its EEPROM marked not bootable, after an unfinished firmware update) enumerates
  as the EZ-USB's default device with the same vendor and product IDs, and the same `bcdDevice` (0x0000), as
  the running firmware: the SL 2's test (`bcdDevice` 0x0100 vs 0x0000) can't tell them apart. Only the
  firmware's descriptors carry strings, so the driver treats a box with no product string as having no
  firmware (`svc_has_firmware`) and never opens it. (Inferred from the EZ-USB's behaviour; not observed.)
  Rane's firmware loader (the bootstrap, loaded by `sl3flash` onto such a box) enumerates exactly like the
  firmware and answers `0x01` with 2.25: the driver reports it as boot mode, sends it nothing at connect, and
  won't stream from it.
- **Opening the box at connect**, as on the SL 2: open once and keep it; look again for the HID interface
  every 100 ms for up to a second; retry a refused first open.
- **At connect, with nothing streaming,** the three decks are put on analogue thru (the box powers up with the
  Aux deck on USB audio, and every deck on USB with external power), and the box is given the driver's rate.
  The link speed is checked (`0x0a`): at full speed the log says so.
- **Status.** At open the driver enables the box's unsolicited reports (`0x36`; the box clears this at every
  enumeration and drops reports raised while it is off), then reads the control bytes (`0x32`) and the
  overload flags (`0x35`). The reports keep them current: `0x38` each deck's LINE/PHONO switch (one physical
  switch per deck), `0x39` each deck's output source and the external-power input, `0x34` the six overload
  flags. The `sl3s` status carries them per deck, in the box's order Aux, Left, Right.
- **Unplugging while streaming**, and **StartIO failing without a box**: as on the SL 2.

### 7. The HID path for clients (`sl3h`, `sl3s`, `sl3q`, `sl3m`, `sl3i`)

- **`sl3h`:** writing a 64-byte command sends it to the box and keeps the reply for the calling process; the
  next read returns it once, and a read never sends anything. The driver tags each request with its own
  sequence number and puts the client's tag back in the reply. Every command waits for its reply except
  `0x06`, which gets none; a reply of `0xFF` with the request's tag means the box refused the command. No
  opcode is blocked (Rane's software has no gate either), so EEPROM-writing commands can be sent: see
  `docs/SL3-COMMANDS.md`.
- **`sl3q`:** the box's unsolicited reports (`0x34`, `0x38`, `0x39`) and the driver's own events (`0x4F`:
  sample rate), kept in a ring of 256 with a read position per client process.
- **`sl3s`:** the status: the SL 2's fields (connected, streaming, rate, version, serial, LINE/PHONO and thru
  per deck, frame counts, boot mode, debug build, input health), then the SL 3's: the overload flags, the
  external-power input and the USB state. Fields are only ever added at the end. The serial is the USB serial
  string, `SL3.01.00` on every SL 3 (the box has no per-unit serial).
- **`sl3i`:** the input safety offset setting, in microseconds. Writing it is refused while a stream runs.
- **`sl3m`:** level meters per client process: the peak of each of the 6 inputs as captured and 6 outputs as
  sent (after the volume) since that client's last read.
- **No heartbeat.** The driver doesn't send `0x37`. The OpenSL3 driver sent one every 100 ms, believing the
  box plays USB audio only while it gets one; the firmware has no watchdog or timer that could act on it,
  Rane's kext never sends it, and the same belief proved false on the SL 2. `make hwtest`'s glitch test runs
  with none. It is sent only when a client asks (Serato's hardware check, below).

### 8. Sl3Api (`tools/Sl3Api.m`)

- A replacement for Rane's `Sl3Api.framework` 2.0.1f2, the library Serato DJ Pro 2.5.5, Rane's "SL 3 Audio
  Control Panel" and its `Sl3SettingsService` load. Newer Serato versions don't load it.
- Every exported function matches Rane's (compared with its disassembly) in arguments, results and return
  codes: 0 ok, 1 the reply was for another command, 2 unknown parameter, 4 no box / no driver / no reply,
  8 a handle that isn't open or a bad argument. (Rane's Sl3Api has no separate "not connected" code: the
  SL2Api's 12 doesn't exist here.) Handles are 1, 2, 3… never reused; callbacks are per handle.
- Serato 2.5.5 imports seven: `sl3_open` (once, when it sees the box on USB; it never calls `sl3_close`),
  `sl3_close`, `sl3_driver_timer` (its genuine-hardware check: an 8-byte `0x37` challenge, compared with its
  own computation; it ignores the return code and doesn't retry), `sl3_get_usb_port_status` (it reads only the
  first word), `sl3_get_audio_controls` and `sl3_set_audio_controls` (each deck's output source, one byte at
  offset 14, 20 or 8 for its decks Left, Right, Aux; byte = !thru), and `sl3_set_thrustate_callback`.
- The box's reports are polled from `sl3q` every 15 ms and passed to every open handle's callbacks on Sl3Api's
  own queue: `0x34` overload (6 bytes), `0x38` LINE/PHONO (3), `0x39` output sources (4). Sl3Api notices the
  box coming and going and calls the port-status callback with `{1, 0}` / `{0, 0}`.
- While the box is in the USB registry and the driver is loaded but hasn't opened it yet, a command waits up
  to 2 s for it (SL 2 catalogue entry 43; Serato checks once and doesn't retry).
- `sl3_get_parameter(0)` reads the rate from the box (`0x30`); `sl3_set_parameter(0, rate)` sets it through
  CoreAudio. The buffer-milliseconds calls keep the control panel's latency value and report the driver's real
  output latency plus safety offset.
- Firmware update and `sl3_set_alt_product_id` (`0x1a`, re-enumerate as product ID 0x0003) are deliberately
  not implemented, and `sl3_is_C0_device` stays 0, so the control panel never starts an update.
  `tools/firmware/sl3flash` does that with safeguards.
- Every exported call is logged at debug level:
  `log stream --level debug --predicate 'subsystem == "com.rane.sl3api"'`.
- `sl3apitest` (`make apitest`) loads the framework from Serato's path and checks the seven calls as Serato
  makes them. Run it as `arch -x86_64 ./sl3apitest` (Serato 2.5.5 is Intel-only) as well as natively.
- **Tested with Serato DJ Pro 2.5.5** and three turntables with control vinyl, on an SL 3 with firmware 2.31
  (2026-11-17): the box is recognised with all three decks; the hardware check passes (Serato opens the
  library, checks the port status, sends the challenge, then opens a second handle, registers its thru
  callback and reads each deck's output source); REL and ABS follow the records on every deck; thru per
  deck; the 1 ms USB buffer (48 frames, an 8.5 ms DVS round trip); timecode at −9 to −11 dBFS on every
  input; a replug with Serato open is picked up again with the decks in their mode (§ bug catalogue 13);
  quitting Serato puts every deck back on thru. During one 5-minute session one millisecond of capture was
  missed (filled with silence, one 3-frame input dropout), during a burst of `0x34` overload reports.

## Platform facts worth knowing

- Real-time priority for USB completion threads is not available from user space, and would not help anyway.
- Completion delivery stalls happen about once a minute, of 5–11 ms, and they are worst when the Mac is idle.
- `ioDataWithCapacity:` buffers keep their interface claimed. Release them before the next stream claims it.
- The HAL reads safety offsets only at device setup. Neither `PropertiesChanged` nor a no-op configuration
  change refreshes them; taking the device out of the device list and putting it back does.
- A HAL plug-in can keep settings across restarts in the storage the HAL keeps for it (`WriteToStorage`,
  `CopyFromStorage`).
- An isochronous transfer scheduled 4 frames ahead was refused (`0xe00002ee`) on an M-series Mac. Start 8 ahead.
- Capture completions are stamped about 0.9 ms into their frame (the last packet is microframe 7, at
  0.875 ms), so the stack stamps at the bus. Only delivery to the handler is delayed.
- Isochronous IN data is in the transfer's buffer before its microframe ends, long before the completion,
  with plain heap buffers too: the controller writes straight into them. The kernel also updates the
  transaction list in our own array (`completeCount`, `timeStamp`) before the completion, 0–2 ms after
  the microframe; the completion handler is passed that same array.
- Under a load that makes the Mac swap (six 4K x264 encodes, 48 GB RAM), the HAL reports IO overloads
  at a 64-frame buffer whatever the driver's safety offsets; the driver had every frame ready.
- When a device disappears while a client streams, the HAL sends that client's StopIO afterwards.
- A HAL client's property query can be answered by the HAL from its own model of the device without reaching
  the plug-in (e.g. `OwnedObjects` with a class qualifier).
- After `killall coreaudiod`, some long-running processes keep stale state:
  - QuickLookUIService and AirPlayXPCHelper ignore SIGTERM and need `kill -9`.
  - Control Center drops the device from its menu until it is restarted.

  `tools/install-sl3.sh` handles this.

## Bug catalogue

Each entry: symptom → cause → fix → how to test for it again → commit. Tests marked *(debug)* need a debug
build; *(hook)* uses `tools/latency/bin/sl3dbg`.

**The shared engine.** The SL 2 driver's catalogue (`docs/SL2-AUDIO-ENGINE.md` there, entries 1–44) covers
the engine this driver shares: the timeline, capture, the deep schedule, teardown, connect and status
handling, the passthrough, and the early read. All of it came to the SL 3 in the commit that rebuilt the
driver on that engine; each of its regression tests applies here, with channel 3 for the loopback.

**Before that commit** the SL 3 driver (from the OpenSL3 project) had, among the SL 2 catalogue's bugs: a
shallow playback queue refilled from completions (SL 2 entries 7, 11), timestamps from completion stamps
(15), no write head on the input ring (21), teardown off the USB queue (22–24), no input safety offset
setting or early read (44), and the heartbeat below.

### SL 3

1. **A 0x37 heartbeat every 100 ms, thought to be needed for USB audio.**
   - Cause: the belief, from probing, that a deck plays USB audio only while the host sends `0x37`. The
     firmware has no watchdog or timer; Rane's kext never sends `0x37`. (Decks going silent when a host stops
     is the output-source bytes left on USB with no audio streaming.)
   - Fix: no heartbeat, as on the SL 2 (its entry 29).
   - Test: `make hwtest ARGS="--loopback"`: "glitch test, 30 s, no heartbeat".
   - In the commit that rebuilt the driver.
2. **The SL 2's bootloader test can't tell an SL 3 with no firmware from a running one.**
   - Cause: both enumerate with `bcdDevice` 0x0000 (the SL 2's firmware uses 0x0100).
   - Fix: a box with no product string has no firmware (`svc_has_firmware`); Rane's loader by its version, 2.25.
   - Test: needs a box with no firmware (after an interrupted `sl3flash`): the status says boot mode.
   - In the commit that rebuilt the driver.
3. **The SL 2's early-read marks don't work on the SL 3's samples.**
   - Cause: the SL 2 counts arrived frames by each sample's pad byte, always 0 in its 4-byte samples; the SL 3's
     are packed in 3 bytes.
   - Fix: buffers filled with `0xA5`; a slot still all mark hasn't arrived; the last frame counts once its last
     sample no longer reads as the mark.
   - Test: `make hwtest`: "early capture read working", and *(debug)* "early capture read" (a 20 ms stall, no gap).
   - In the commit that rebuilt the driver.
4. **Sl3Api's exports didn't match Rane's.**
   - Cause: written without Rane's framework to compare against: any non-NULL handle accepted and handles
     reused; return codes 1 and 4 missing where Rane's gives them; wrong signatures for
     `sl3_set_alt_product_id` and the firmware calls; a 2 + len byte `0x33`; callbacks from status polling.
   - Fix: every export as Rane's (§8).
   - Test: `sl3apitest`, both slices; Serato DJ Pro 2.5.5 with turntables.
5. **sl3panel took the box from the driver.**
   - Cause: it opened the HID interface itself, which the driver holds whenever it runs.
   - Fix: it goes through `sl3s`, `sl3h` and `sl3i`.
   - Test: `sl3panel` while Serato streams.
6. **The protocol notes listed `0x17` as "probably firmware version".**
   - Cause: a guess from probing. `0x17` marks the EEPROM not bootable.
   - Fix: `docs/SL3-COMMANDS.md`, with every EEPROM-writing command marked; nothing in this project sends
     `0x17` except `sl3flash`.
7. **Rane's firmware loader was reported as running firmware, and sent thru commands at connect.**
   - Cause: boot mode, set from the loader's version, was cleared again after the box was opened; `0x33` at
     connect.
   - Fix: boot mode kept; nothing sent to the loader at connect; no streaming from it.
   - Found by reading the code.
8. **A box that didn't answer `0x01` kept the previous box's version** (so the box back from a flash
   could be taken for the loader, or the loader for the firmware).
   - Fix: the version and USB state are cleared before the box is asked. Found in review. `6134cba`.
9. **An unplug elsewhere cleared the loader's boot mode** (boot mode after a removal came only from boxes
   with no strings).
   - Fix: a removal keeps boot mode if the attached box's version is the loader's. Found in review. `7449d64`.
10. **The early read could take a frame whose last sample was part-written.**
    - Fix: the frame's last byte (its last sample's top byte) decides. Found in review. `0d6cf1b`.
11. **Sl3Api deadlocked if a callback called back into it** (callbacks ran with its lock held).
    - Fix: callbacks are called outside the lock. Found in review. `10edc3d`.
12. **After a Mac sleep the decks were on USB audio and the box at 44.1 kHz** (firmware 2.31's DSP boot).
    - Fix: the settle check, 2 s after connect and 4 s after a wake. Confirmed on the box. `79078e6`.
    - Test: `make hwtest`, "thru and rate after the Mac sleeps".
13. **After a replug mid-stream, Serato DJ Pro 2.5.5 put every deck in THRU.**
    - Cause: the driver put every deck on thru at connect; Serato, reconnecting by itself, read the output
      sources before restarting its stream and adopted thru (timecode to the mixer).
    - Fix: the routing at an unplug while streaming is restored at connect and at the next stream start
      (box back within 30 s; thru if no stream within 5 s). Confirmed with Serato: the decks stay in REL.
      `5fd6505`.
14. **The status kept a deck's old thru state when a client switched it** (2.31 has no `0x39` report).
    - Fix: the driver's status follows a client's accepted `0x33`. `43bc298`.

## Testing

`make hwtest` runs the hardware tests in one go, in the order that needs the fewest physical steps, and
ends with a PASS / FAIL / SKIP summary (`ARGS="--loopback"` with the loopback cable in, Left Deck Out L
to Left Deck In L: channel 3). It covers the status, Sl3Api as Serato calls it, rate switching, the
phono sensitivity, the input safety offset setting, the early capture read working (no cable needed),
restarts, glitches with no 0x37 heartbeat sent (idle and loaded), the other rate, IO buffer sizes at both
rates, the output volume and mute (and that they survive a replug), the level meters, the capture packet
sizes, the early capture read, the fault hooks, each deck's LINE/PHONO switch, and unplug and replug while
idle and mid-stream.

The tools are in `tools/latency/` (build them with `make latency`). Its README covers the loopback setup,
what each tool does and the expected results. The main ones:

| Tool | What it does |
|---|---|
| `rtlat` | Round-trip latency through a loopback cable: hidden latency and estimated DVS round trip |
| `sinetest` | Plays a continuous 997 Hz sine through the loopback for N seconds. Flags any break in the sine recurrence (dropout, repeat, skip) and any drop in level |
| `dptest.sh` | `sinetest` for N s idle, then with every core busy, with the driver's counters (debug build); PASS/FAIL |
| `restartcheck.sh` | Three streams in a row; each must start cleanly and find its clicks; PASS/FAIL |
| `sl3dbg` | Debug build only: stall the USB queue, error capture packets, switch the early read off |

`tools/install-sl3.sh` (run by `make install`) installs a build into the installed driver bundle (the
release package must be installed first) and restarts coreaudiod and the processes that go stale.
`--api` also installs a built Sl3Api into `Sl3Api.framework`, saving the previous one, which
`--restore-api` puts back.

**Debug build.** `make plugin DEBUG=1` defines `SL3_DEBUG`, which compiles in the streaming diagnostics
(counters, the capture timing histogram, the WriteMix calling-pattern check) and the debug commands
(`sl3dbg`). A plain `make plugin` builds none of it, refuses every debug command, and logs only: driver
start, connect and disconnect, bootloader mode, opens that needed a retry, stream start and stop, sample-rate
changes, capture gaps, refusals and errors. Both builds play through the deep schedule.

**Superseded code, kept in history.** The SL 2 driver's history holds the shallow-queue playback path,
the late-write experiment and the workloop / real-time attempts (`docs/SL2-AUDIO-ENGINE.md` there). This
repository's history holds the OpenSL3 driver this one replaced, and the OpenSL3 bridge and tools.

**Driver counters.** The debug build logs `DBG dp` every ~2 s and a result line at stream stop. They should read:
- `late 0`;
- `unscheduled` flat after start-up;
- `enqueue refused 0`;
- `resyncs 0`;
- sent − captured within ±2;
- `rewritten samples 0`;
- `capture packet errors` rarely above 0;
- `DBG early read`: `completion found 0 different`, `SILENCE (not captured yet) 0`, and a least margin
  above 0.5 ms (at the 1.5 ms input safety offset);
- `DBG capture packet sizes` (at stream stop): 5 and 6 frames at 44.1 kHz, 6 at 48 kHz.

**Debug commands** (`tools/latency/bin/sl3dbg`, handled by the driver, never sent to the box):
- `stall <ms>`: hold the USB queue once, as a completion-delivery stall would. A stall shorter than the
  capture queue (about 50 ms) is covered by the early read; a longer one leaves a gap and a "not
  captured" line.
- `errpkts <n>`: treat the next n capture packets as errored.
- `noearly 1|0`: switch the early capture read off (on), as on a Mac where it can't work: the next
  stream judges it not working.

## Still open

- **Measured on an SL 3 (firmware 2.31)**: the round trip at every IO buffer from 32 to 512 frames at both
  rates, the latency to report, the early read's margin, that the box takes predicted OUT packet sizes
  (sent − captured within 2), no heartbeat needed, the packet sizes (5/6 frames at 44.1 kHz; 6 at 48 kHz with
  about 0.5% of 5s and 7s as the box corrects its clock), the channel order (a loopback on each deck:
  1 = Aux L, 3 = Left Deck L, 5 = Right Deck L, each with an 11.8–11.9 ms round trip at 128 frames and a
  clean 20 s glitch test).
- **Two glitchy runs** (see Results), cause unknown, not reproduced.
- **Also confirmed on the SL 3:** each deck's LINE/PHONO report (`0x38`; the box doesn't debounce, so
  readings can flicker for ~0.2 s while a switch moves), unplug and replug idle and mid-stream (every deck
  back on thru, volume and mute kept, coreaudiod unaffected), every deck switched to USB and back through
  Sl3Api.
- **The settle check after a Mac sleep**, confirmed: the USB suspend turned the box's yellow light off, and
  after the wake the driver logged "a deck was on USB audio with nothing streaming: back to thru" and "the
  box was at 44100 Hz: set to 48000 Hz", as the 2.31 firmware's DSP boot predicts. `make hwtest` has a
  step for it (skipped while something holds a PreventSystemSleep assertion, as Internet Sharing does).
- **Still to confirm on the hardware:** the settle check after a slow DSP boot at connect; the right-hand
  channels (2, 4, 6) carrying audio; how a box with no firmware enumerates; firmware 2.50 (the box tested
  runs 2.31); the firmware tools; Serato DJ Pro 2.5.5 with turntables; Serato 4.x / 5.x.
- **Control bytes 4–7 of each deck's block** are passed to the DSP with unknown meaning (two 0–127 values at
  96, two flags at 0). One of them may be a level.
- **The overload flags**: which six signals they are.
- **The firmware tools** (`tools/firmware/`) have not been run on an SL 3.
- **Serato DJ Pro 4.x / 5.x**: untested.
- **One missed millisecond of capture with Serato** (see §8): whether the box's overload reports, about 30 a
  second while a flag toggles, can delay the capture completions on the shared USB queue. The overload
  flags' mapping to channels is also unknown.
- The output side (2 ms safety offset + 1.5 ms output latency) is set by the 1 ms write guard and 1 ms
  transfers; shorter transfers or a smaller guard might save up to ~1 ms. Untested on either box.
