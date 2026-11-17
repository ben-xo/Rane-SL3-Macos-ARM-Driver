# Rane SL 3 firmware tools

Everything for getting firmware onto a Rane SL 3. The SL 3's USB controller (a Cypress EZ-USB FX2)
has no internal flash: its firmware, the 8051's code and the program for the box's DSP, lives in
an on-board I2C EEPROM, which the box boots from at every power-up. If the EEPROM is marked not
bootable (a firmware update that didn't finish) the box comes up as the EZ-USB's default device,
with the SL 3's vendor and product IDs but no strings and no audio. A healthy box runs as "SL 3"
and answers firmware version 2.50.

The firmware is Rane's and is **not** included here. You extract it from **your own** copy of
Rane's SL 3 driver, `RaneSL3_2.0.1f2.pkg`, with `extract-sl3-firmware.py`; `.gitignore` keeps the
extracted images out of the repository. (Serato DJ Pro 2.5.5 carries that package among its
resources and offers to install it when an SL 3 is connected; it is also in Rane's and Serato's
driver archives.)

## Writing it over USB, with `sl3flash`

`sl3flash` programs the EEPROM through the box's own USB command interface, as Rane's driver did:

- **a running box** directly (a firmware update);
- **a box with no firmware** after first loading Rane's bootstrap, a small EEPROM writer, into its
  RAM over EP0 (the EZ-USB `0xA0` request). The bootstrap then enumerates exactly like a running
  box (it answers version 2.25) and is programmed the same way.

The commands go through this project's HAL driver, so the driver must be installed. Only the
image's 0x38C0 bytes are written; the phono sensitivities the box keeps at 0x3FC0-0x3FC2 are left
alone. Before writing, `sl3flash` saves the whole EEPROM to `sl3-eeprom-backup-<date>.bin` in the
current directory. It verifies every block as it writes and the whole image afterwards, and only
then marks the EEPROM bootable (`0x16`); if anything fails before that, the box keeps running until
it is power-cycled, and running `sl3flash` again finishes the job.

The protocol is in `docs/SL3-COMMANDS.md` ("Firmware storage and boot", and the ⚠ commands).

**Not yet tested on hardware.** Neither path has been run on an SL 3. The SL 2's equivalent
(`sl2flash`) was proven on its hardware for both paths, and the SL 3's firmware implements the same
commands with the same layout, but test with a SOIC-8 clip and a programmer at hand: a box that no
longer enumerates at all can only be recovered by writing the EEPROM chip directly (from
`eeprom-image-sl3.bin`, or from the backup `sl3flash` saved).

## Usage

```
tools/firmware/extract-sl3-firmware.py RaneSL3_2.0.1f2.pkg          # into sl3-fw-out/
sudo tools/firmware/sl3-firmware-install.sh sl3-fw-out/sl3_*_firmware.bin
make flash dump
./sl3dump sl3-eeprom-before.bin     # a backup of a running box's EEPROM
./sl3flash --dry-run                # check the images and the box; change nothing
./sl3flash                          # write the firmware if the EEPROM doesn't already hold it
./sl3dump --verify sl3-fw-out/eeprom-image-sl3.bin   # independent check of a running box's EEPROM
```

`sl3flash` reads the images from `/Library/Audio/Plug-Ins/HAL/SL3Device.firmware` (where
`sl3-firmware-install.sh` puts them), or from `--firmware DIR`. It needs no root. Stop any audio
on the SL 3 and quit sl3panel, the SL 3 Control Panel and Serato first: they talk to the box
through the same driver channel.

## Files
- `extract-sl3-firmware.py` — de-obfuscate the firmware out of your own copy of Rane's Sl3Api
  (from the package, the expanded package, or the binary); checks the Rane header's length and
  CRC-32 and the SHA-256 of the known build. Produces the final image and the bootstrap (for
  `sl3flash`) and `eeprom-image-sl3.bin` (for `sl3dump --verify`, or the chip).
- `sl3flash.m` — the over-USB flasher.
- `sl3-firmware-install.sh` — install firmware images next to the HAL driver for `sl3flash`.

Outside this folder: `tools/sl3dump.m` reads the EEPROM of a running box over USB (backup and
verify), and `tools/SL3Passthrough.{h,m}`, shared by both tools, sends commands to the box through
the HAL driver.

## Licensing
The firmware is proprietary Rane / Serato code, extracted only for interoperability with hardware
you own. Do not commit the extracted images or redistribute them — supply your own copy of the
official driver.
