// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl3panel.m — Rane SL 3 status and control from the command line
 *
 * Works while CoreAudio / Serato is streaming: everything goes through the SL3Device HAL plug-in
 * ('sl3s' status, 'sl3h' commands, 'sl3i' input safety offset), which holds the box.
 *
 *   sl3panel [status]                    the box's and the driver's state
 *   sl3panel usb|thru [aux|left|right]   each deck's (or one deck's) output: USB audio or analogue thru
 *   sl3panel sens aux|left|right <mV>    a deck's phono sensitivity, 2.5-10 mV in 0.5 mV steps
 *                                        (kept in the box's EEPROM, as Rane's control panel does)
 *   sl3panel sr 44100|48000              the sample rate (through CoreAudio, so the HAL follows)
 *   sl3panel safety [ms]                 the input safety offset setting
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import "SL3Passthrough.h"

#ifndef SL3_VERSION
#define SL3_VERSION  "1.4.0"
#endif
#define kSL3PropStatus      'sl3s'
#define kSL3PropInSafety    'sl3i'

/* The control block: a block of six per deck, Aux, Left, Right (docs/SL3-COMMANDS.md). */
#define CTL_LINE_PHONO(d)   (d)                    /* 0-2 */
#define CTL_SENSITIVITY(d)  (3 + 6 * (d))          /* 3, 9, 15 */
#define CTL_SOURCE(d)       (3 + 6 * (d) + 5)      /* 8, 14, 20: 1 = USB, 0 = thru */
#define CTL_EXT_POWER       21
static const char *const kDeckNames[3] = { "aux", "left", "right" };
static const char *const kDeckLabels[3] = { "Aux       ", "Left Deck ", "Right Deck" };

#include "SL3Status.h"   /* the driver's status packet ('sl3s') */

/* An SL 3 is in the USB registry. The driver only lists its device while a box is attached, so this
   tells "no box" from "driver not loaded". */
static bool sl3_on_usb(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = 0x1cc5, p = 0x0001;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) return false;
    IOObjectRelease(svc);
    return true;
}

static int deck_index(const char *name) {
    for (int d = 0; d < 3; d++) if (strcmp(name, kDeckNames[d]) == 0) return d;
    return -1;
}

static void print_status(AudioObjectID dev) {
    /* Read the driver's status ('sl3s'). */
    AudioObjectPropertyAddress a = { kSL3PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr || !d) {
        printf("Error: Could not read SL 3 status from CoreAudio HAL.\n");
        return;
    }
    SL3StatusPacket s;
    memset(&s, 0, sizeof s);
    CFIndex n = CFDataGetLength(d);
    memcpy(&s, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof s ? n : (CFIndex)sizeof s));
    CFRelease(d);

    /* Print it; a box with no firmware running has no other status to show. */
    printf("==================================================\n");
    printf("  Rane SL 3 — Hardware & CoreAudio Status\n");
    printf("==================================================\n");
    printf("  USB Connected : %s\n", s.connected ? "YES" : "NO");
    printf("  Driver Build  : %s\n", s.debug_build ? "DEBUG" : "release");
    if (s.boot_mode) {
        printf("  Firmware      : NOT RUNNING — the box needs its firmware restored\n");
        printf("==================================================\n");
        return;
    }
    printf("  Streaming I/O : %s\n", s.streaming ? "ACTIVE" : "IDLE");
    printf("  Sample Rate   : %u Hz\n", s.sample_rate);
    /* The box's own rate (0x30), which can differ from the driver's if the box has reset it. */
    unsigned box_hz = 0;
    if (s.connected && sl3h_get_rate(dev, &box_hz)) printf("  Box Rate      : %u Hz\n", box_hz);
    printf("  Firmware Ver  : %u.%02u\n", s.version_maj, s.version_min);
    printf("  USB Link      : %s\n", s.usb_state == 2 ? "high speed" : s.usb_state == 1 ? "FULL SPEED (no audio: use a USB 2.0 port)" : "?");
    /* The phono sensitivities are only in the control block: ask the box. */
    uint8_t c[SL3_CONTROLS_LEN];
    bool have_c = s.connected && sl3h_get_controls(dev, c);
    for (int k = 0; k < 3; k++) {
        printf("  %s: %s  |  Mode: %-11s", kDeckLabels[k], s.phono[k] ? "PHONO" : "LINE ", s.thru[k] ? "ANALOG THRU" : "USB AUDIO");
        if (have_c) printf("  |  Phono sens: %.1f mV", 2.5 + 0.5 * c[CTL_SENSITIVITY(k)]);
        printf("\n");
    }
    printf("  Overload      : %u %u %u %u %u %u\n", s.overload[0], s.overload[1], s.overload[2], s.overload[3], s.overload[4], s.overload[5]);
    printf("  Ext. Power    : %u\n", s.ext_power);
    printf("  Captured Frms : %llu\n", s.cap_frames);
    printf("  Playback Frms : %llu\n", s.play_frames);
    if (s.in_safety_us) {
        printf("  Input Safety  : %g ms\n", s.in_safety_us / 1000.0);
        printf("  Early Read    : %s\n", s.early_read == 1 ? "working" : s.early_read == 2 ? "NOT WORKING (use an input safety offset of 8 ms)" : "not judged yet");
        printf("  Input Dropouts: %llu\n", s.in_dropouts);
        printf("  USB Hubs      : %u%s\n", s.hub_depth, s.hub_depth ? "" : " (connected directly)");
    }
    printf("==================================================\n");
}

static int usage(void) {
    printf("Usage: sl3panel [status | usb [aux|left|right] | thru [aux|left|right] |\n"
           "                sens aux|left|right <mV> | sr 44100|48000 | safety [ms]]\n");
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
            printf("sl3panel %s\n", SL3_VERSION);
            return 0;
        }
        /* Find the driver's device; without it, say whether a box is attached at all. */
        AudioObjectID dev = sl3h_find_device();
        if (dev == kAudioObjectUnknown) {
            if (sl3_on_usb())
                printf("Error: an SL 3 is connected, but the SL 3 CoreAudio driver is not loaded in coreaudiod.\n");
            else
                printf("No SL 3 connected.\n");
            return 1;
        }
        /* No command, or "status": print the status. */
        if (argc < 2 || strcmp(argv[1], "status") == 0) {
            print_status(dev);
            return 0;
        }
        /* "usb" / "thru" [deck]: each deck's output source byte (1 = USB audio, 0 = analogue thru). */
        if (strcmp(argv[1], "usb") == 0 || strcmp(argv[1], "thru") == 0) {
            int only = argc >= 3 ? deck_index(argv[2]) : -1;
            if (argc >= 3 && only < 0) return usage();
            uint8_t v = strcmp(argv[1], "usb") == 0 ? 1 : 0;
            for (int k = 0; k < 3; k++) {
                if (only >= 0 && k != only) continue;
                if (!sl3h_set_controls(dev, CTL_SOURCE(k), 1, &v)) { printf("Error: the box did not answer.\n"); return 1; }
                printf("%s: %s\n", kDeckLabels[k], v ? "USB audio" : "analogue thru");
            }
        /* "sens" deck mV: the phono sensitivity, 0-15 for 2.5-10 mV. */
        } else if (strcmp(argv[1], "sens") == 0 && argc >= 4) {
            int k = deck_index(argv[2]);
            double mv = atof(argv[3]);
            int step = (int)lround((mv - 2.5) / 0.5);
            if (k < 0 || step < 0 || step > 15) return usage();
            uint8_t v = (uint8_t)step;
            if (!sl3h_set_controls(dev, CTL_SENSITIVITY(k), 1, &v)) { printf("Error: the box did not answer.\n"); return 1; }
            printf("%s: phono sensitivity %.1f mV\n", kDeckLabels[k], 2.5 + 0.5 * step);
        /* "sr": set the rate through CoreAudio, which changes the box's rate with it. */
        } else if (strcmp(argv[1], "sr") == 0 && argc >= 3) {
            Float64 sr = atof(argv[2]);
            AudioObjectPropertyAddress a = {
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            if (AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &sr)) { printf("Refused: 44100 or 48000.\n"); return 1; }
            printf("Set Sample Rate to %.0f Hz.\n", sr);
        } else if (strcmp(argv[1], "safety") == 0) {
            /* "safety [ms]": the input safety offset setting. The driver takes it only with nothing
               streaming, and sets the device up again with it (about half a second). */
            AudioObjectPropertyAddress a = { kSL3PropInSafety, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            if (argc >= 3) {
                int us = (int)lround(atof(argv[2]) * 1000.0);
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &us);
                OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof n, &n);
                CFRelease(n);
                if (e) {
                    printf("Refused (error %d): the setting must be 0.5 to 20 ms, with nothing streaming.\n", (int)e);
                    return 1;
                }
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            } else {
                CFNumberRef n = NULL;
                UInt32 sz = sizeof n;
                int us = 0;
                if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &n) || !n) {
                    printf("This driver has no input safety offset setting.\n");
                    return 1;
                }
                CFNumberGetValue(n, kCFNumberIntType, &us);
                CFRelease(n);
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            }
        } else {
            /* LINE/PHONO is a physical switch per deck: reported in the status, not settable */
            return usage();
        }
    }
    return 0;
}
