// SPDX-License-Identifier: GPL-3.0-or-later
/* SL3Passthrough.m — see SL3Passthrough.h. */
#import "SL3Passthrough.h"
#import <Foundation/Foundation.h>
#include <string.h>

#define kSL3PropHIDCommand  'sl3h'
#define OP_VERSION       0x01
#define OP_WRITE         0x02
#define OP_READ          0x03
#define OP_GET_RATE      0x30   /* reply [5..6] the box's rate, big-endian */
#define OP_GET_CONTROLS  0x32
#define OP_SET_CONTROLS  0x33

AudioObjectID sl3h_find_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl3.hal.device");
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev);
    return (st == noErr) ? dev : kAudioObjectUnknown;
}

bool sl3h_command(AudioObjectID dev, uint8_t req[SL3_REPORT], uint8_t reply[SL3_REPORT]) {
    /* A non-zero tag: the driver puts it back in the box's reply. */
    static uint32_t tag = 0;
    if (++tag == 0) tag = 1;
    memcpy(req + 1, &tag, 4);

    /* Write the command (the driver sends it), then read this process's reply. */
    AudioObjectPropertyAddress a = { kSL3PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, SL3_REPORT);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);
    if (st != noErr) return false;

    CFDataRef out = NULL;
    UInt32 sz = sizeof(out);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) != noErr || !out) return false;
    memset(reply, 0, SL3_REPORT);
    CFIndex n = CFDataGetLength(out);
    memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < SL3_REPORT ? n : SL3_REPORT));
    CFRelease(out);
    return reply[0] == req[0] && memcmp(reply + 1, req + 1, 4) == 0;
}

bool sl3h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor) {
    uint8_t req[SL3_REPORT] = { OP_VERSION }, reply[SL3_REPORT];
    if (!sl3h_command(dev, req, reply)) return false;
    *major = reply[5];
    *minor = reply[6];
    return true;
}

bool sl3h_get_rate(AudioObjectID dev, unsigned *hz) {
    uint8_t req[SL3_REPORT] = { OP_GET_RATE }, reply[SL3_REPORT];
    if (!sl3h_command(dev, req, reply)) return false;
    *hz = (unsigned)(reply[5] << 8 | reply[6]);
    return true;
}

bool sl3h_get_controls(AudioObjectID dev, uint8_t out[SL3_CONTROLS_LEN]) {
    uint8_t req[SL3_REPORT] = { OP_GET_CONTROLS }, reply[SL3_REPORT];
    if (!sl3h_command(dev, req, reply)) return false;
    memcpy(out, reply + 5, SL3_CONTROLS_LEN);
    return true;
}

bool sl3h_set_controls(AudioObjectID dev, uint8_t first, uint8_t count, const uint8_t *values) {
    if (count == 0 || first + count > SL3_CONTROLS_LEN) return false;
    uint8_t req[SL3_REPORT] = { OP_SET_CONTROLS }, reply[SL3_REPORT];
    req[5] = first;
    req[6] = count;
    memcpy(req + 7, values, count);
    return sl3h_command(dev, req, reply);
}

/* 0x02 and 0x03 echo the address at reply[5..6]; checking it as well as the tag guards against
   a reply that belongs to a different block. */
static bool eeprom_cmd(AudioObjectID dev, uint8_t op, uint16_t addr, const uint8_t *data, uint8_t out[SL3_EEPROM_BLOCK], int attempts) {
    for (int i = 0; i < attempts; i++) {
        uint8_t req[SL3_REPORT] = { op }, reply[SL3_REPORT];
        req[5] = (uint8_t)(addr >> 8);
        req[6] = (uint8_t)(addr & 0xFF);
        if (data) memcpy(req + 7, data, SL3_EEPROM_BLOCK);
        if (sl3h_command(dev, req, reply) && reply[5] == req[5] && reply[6] == req[6]) {
            memcpy(out, reply + 7, SL3_EEPROM_BLOCK);
            return true;
        }
    }
    return false;
}

bool sl3h_eeprom_read(AudioObjectID dev, uint16_t addr, uint8_t out[SL3_EEPROM_BLOCK]) {
    return eeprom_cmd(dev, OP_READ, addr, NULL, out, 3);
}

/* Rewriting a block with the same data is harmless, so a write whose reply went missing is
   simply sent again. */
bool sl3h_eeprom_write(AudioObjectID dev, uint16_t addr, const uint8_t data[SL3_EEPROM_BLOCK],
                       uint8_t readback[SL3_EEPROM_BLOCK]) {
    return eeprom_cmd(dev, OP_WRITE, addr, data, readback, 2);
}

bool sl3h_is_streaming(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 running = 0, sz = sizeof(running);
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &running) == noErr && running;
}
