// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL3Passthrough — send commands to a Rane SL 3 through the HAL driver's 'sl3h' property.
 *
 * While the HAL plug-in (plugin/SL3Device.m) runs, it holds the box's USB interfaces, so a tool
 * cannot open the command endpoints itself. Instead it writes a 64-byte command report to the
 * driver's 'sl3h' property, which sends it to the box, and then reads the property back, which
 * returns the box's reply to this process (once). The report layout and the command set are in
 * docs/SL3-COMMANDS.md.
 *
 * Each process gets its own reply, but one process should send one command at a time. Run tools
 * that write the EEPROM as the only client.
 */
#import <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define SL3_REPORT        64
#define SL3_CONTROLS_LEN  22      /* the audio control block (0x32 / 0x33) */
#define SL3_EEPROM_SIZE   0x4000  /* the firmware reads up to 0x3FC2 */
#define SL3_EEPROM_BLOCK  32      /* bytes per 0x02 write / 0x03 read */

/* The SL 3's HAL device, or kAudioObjectUnknown if the driver is not loaded or no box is attached
   (the driver lists the device only while one is). */
AudioObjectID sl3h_find_device(void);

/* Send one command report and fetch its reply. Fills in the tag (req[1..4]) itself. True if the
   reply echoes the opcode and tag; the driver returns an all-zero reply when the box does not
   answer in time, so a timeout reads as false too, and so does a rejection (0xFF). */
bool sl3h_command(AudioObjectID dev, uint8_t req[SL3_REPORT], uint8_t reply[SL3_REPORT]);

/* Command 0x01: the firmware version (02 32 = 2.50 from the running firmware, 02 19 = 2.25 from
   Rane's RAM-loaded EEPROM writer). */
bool sl3h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor);

/* Command 0x30: the box's own sample rate (its clock, which can differ from the driver's if the box
   has reset it), in Hz. */
bool sl3h_get_rate(AudioObjectID dev, unsigned *hz);

/* Command 0x32: the 22 control bytes. */
bool sl3h_get_controls(AudioObjectID dev, uint8_t out[SL3_CONTROLS_LEN]);

/* Command 0x33: write control bytes first..first+count-1. The box skips bytes 0 and 1 (and
   overwrites byte 2 from its switch) and any value above a byte's maximum, without saying so. */
bool sl3h_set_controls(AudioObjectID dev, uint8_t first, uint8_t count, const uint8_t *values);

/* Command 0x03: read 32 EEPROM bytes at 'addr'. */
bool sl3h_eeprom_read(AudioObjectID dev, uint16_t addr, uint8_t out[SL3_EEPROM_BLOCK]);

/* Command 0x02: write 32 EEPROM bytes at 'addr' (only accepted after 0x17); 'readback' gets the
   bytes the box read back from the EEPROM after the write cycle. */
bool sl3h_eeprom_write(AudioObjectID dev, uint16_t addr, const uint8_t data[SL3_EEPROM_BLOCK],
                       uint8_t readback[SL3_EEPROM_BLOCK]);

/* True if any process is doing audio I/O on the SL 3. */
bool sl3h_is_streaming(AudioObjectID dev);
