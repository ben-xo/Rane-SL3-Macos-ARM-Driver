// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl3flash — write the Rane SL 3's firmware into its boot EEPROM over USB.
 *
 *   sl3flash [--firmware DIR] [--force] [--dry-run] [--wait SECONDS] [--blank-fx2]
 *     --firmware DIR  directory holding the firmware images (*.bin, recognised by content);
 *                     default: /Library/Audio/Plug-Ins/HAL/SL3Device.firmware
 *     --force         rewrite the EEPROM even if it already holds the image
 *     --dry-run       check the images and the box (and compare its EEPROM with the image)
 *                     without changing anything
 *     --wait SECONDS  wait up to this long for a box to be connected
 *     --blank-fx2     also take a Cypress FX2 with a blank EEPROM (04b4:8613) as the SL 3: any
 *                     other device built on a blank FX2 (a logic analyser, say) shows up the same
 *
 *   Exit status: 0 done, or nothing to do; 1 failed; 2 bad arguments; 3 (--dry-run only) the
 *   box needs writing.
 *
 * The SL 3 is a Cypress EZ-USB FX2 (8051) whose firmware — the 8051's code and the program for the
 * box's DSP — lives in an I2C EEPROM (docs/SL3-COMMANDS.md, "Firmware storage and boot"). Byte 0 of
 * the EEPROM is the FX2 boot byte: 0xC2 boots the firmware; 0xC0 gives the FX2 only the USB
 * identity, so the box comes up as the EZ-USB's default device under the SL 3's IDs, with no
 * strings and no audio. An FX2 with a blank EEPROM enumerates as Cypress's 04b4:8613.
 *
 * Programming takes four commands on the box's EP1 command interface: 0x17 marks the EEPROM not
 * bootable, 0x02 writes 32-byte blocks (each reply carries the block read back), 0x03 reads blocks,
 * 0x16 marks the EEPROM bootable and restarts the box. The running firmware implements them, and so
 * does Rane's bootstrap, a small EEPROM writer:
 *
 *   - a running box is programmed directly;
 *   - a box with no firmware first has the bootstrap loaded into its RAM over EP0 with the EZ-USB
 *     0xA0 vendor request ("stage 1"). The bootstrap then enumerates exactly like a running box
 *     (it answers 0x01 with 2.25, where the firmware answers 2.50) and is programmed the same way.
 *
 * The commands go through the HAL driver's 'sl3h' passthrough (tools/SL3Passthrough.h): the driver
 * holds the EP1 interface of a running box, and of the bootstrap, which looks the same to it. So the
 * driver must be installed, and no other 'sl3h' client (sl3panel, the control panel, Serato) may run
 * during a flash. Stage 1 opens the box directly (no root needed); the driver never opens a box with
 * no firmware.
 *
 * Only the image's 0x38C0 bytes are written, from address 0. The box keeps the phono sensitivities
 * at 0x3FC0-0x3FC2, beyond the image, and they are left as they are. Before anything is written, the
 * whole EEPROM (16 KiB) is saved to sl3-eeprom-backup-<date>.bin in the current directory.
 *
 * The EEPROM is read first. If it already holds the image, a running box is left alone and a box
 * running the bootstrap is only marked bootable again (0x16), unless --force is given. Otherwise
 * every block is written and checked against its read-back, and then the whole image range is read
 * again and compared with the image before 0x16 makes it bootable. If anything fails before 0x16,
 * byte 0 stays 0xC0: a running box keeps working until it is power-cycled, then comes up with no
 * firmware, and running sl3flash again finishes the job.
 *
 * The images come from the user's own copy of Rane's driver (tools/firmware/extract-sl3-firmware.py);
 * they are not distributed with this project. Build: make flash
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#import "SL3Passthrough.h"

#define SL3_VID          0x1cc5
#define SL3_PID          0x0001
#define FX2_DEFAULT_VID  0x04b4
#define FX2_DEFAULT_PID  0x8613

#define FX2_CPUCS    0xE600   /* CPU control/status: bit 0 = 8051 in reset */
#define FX2_REQ_RAM  0xA0     /* EZ-USB vendor request: RAM read/write */
#define RAM_CHUNK    32

#define OP_FINALIZE  0x16
#define OP_BEGIN     0x17
#define HDR_BOOT     0xC2     /* EEPROM byte 0: boot the firmware */
#define HDR_NOBOOT   0xC0     /* EEPROM byte 0: USB identity only (no firmware runs) */

#define RANE_HDR     0x40     /* header in front of the EEPROM contents in the final image */
#define IMAGE_LEN    0x38C0   /* EEPROM bytes the final image holds */
#define BOOTSTRAP_VERSION 0x0219

#define EXIT_WOULD_WRITE 3

static const char *kDefaultDir = "/Library/Audio/Plug-Ins/HAL/SL3Device.firmware";

/* ---- firmware images ---- */

/* The final image is a 0x40-byte Rane header — "Copyright 20?? Rane Corporation", the firmware
   version at 0x27/0x28, the payload length at 0x38 and its CRC-32 at 0x3C (both big-endian) —
   followed by the EEPROM contents. */
static bool is_final_image(NSData *d) { return d.length > RANE_HDR && memcmp(d.bytes, "Copyright 20", 12) == 0; }

/* The bootstrap is raw 8051 code loaded at address 0; it starts with an LJMP (0x02). */
static bool is_bootstrap_image(NSData *d) { return d.length > 3 && d.length <= 0x4000 && ((const uint8_t *)d.bytes)[0] == 0x02; }

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

static uint32_t crc32_std(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) { c ^= p[i]; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u))); }
    return c ^ 0xFFFFFFFFu;
}

typedef struct { NSData *data; NSString *name; } image_t;

/* Keep the first candidate for a slot; a second one with different contents is ambiguous. */
static bool take(image_t *slot, NSData *x, NSString *f, const char *kind) {
    if (slot->data && ![slot->data isEqualToData:x]) {
        printf("both %s and %s look like the %s image; leave only one\n", slot->name.UTF8String, f.UTF8String, kind);
        return false;
    }
    if (!slot->data) { slot->data = x; slot->name = f; }
    return true;
}

/* Pick the final image and the bootstrap out of DIR. Other .bin files (EEPROM dumps and backups,
   the EEPROM image) are ignored. */
static bool load_images(const char *dir, image_t *final, image_t *boot) {
    NSString *d = [NSString stringWithUTF8String:dir];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:d error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (!files) { printf("cannot read the firmware directory %s\n", dir); return false; }
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"bin"]) continue;
        NSData *x = [NSData dataWithContentsOfFile:[d stringByAppendingPathComponent:f]];
        if (is_final_image(x)     && !take(final, x, f, "final"))     return false;
        if (is_bootstrap_image(x) && !take(boot,  x, f, "bootstrap")) return false;
    }
    if (!final->data) { printf("no final firmware image (\"Copyright 20.. Rane Corporation\" header) in %s\n", dir); return false; }

    /* The header's length and CRC, the SL 3's IDs, and the identity the box forces into EEPROM
       bytes 0-4 whenever block 0 is written (the image must hold the same, or the read-back would
       never match). */
    const char *name = final->name.UTF8String;
    const uint8_t *img = final->data.bytes;
    uint32_t plen = be32(img + 0x38), pcrc = be32(img + 0x3C);
    if (plen != IMAGE_LEN || final->data.length != RANE_HDR + plen) {
        printf("%s: payload is %u bytes (file %lu bytes); expected the SL 3's 0x%x\n",
               name, plen, (unsigned long)final->data.length, IMAGE_LEN);
        return false;
    }
    uint32_t crc = crc32_std(img + RANE_HDR, plen);
    if (crc != pcrc) { printf("%s: CRC %08x does not match its header (%08x)\n", name, crc, pcrc); return false; }
    static const uint8_t ids[6] = { 0x01, 0x1C, 0xC5, 0x00, 0x01, 0x00 };   /* header 0x20: VID, PID */
    static const uint8_t ident[5] = { HDR_NOBOOT, 0xC5, 0x1C, 0x01, 0x00 };
    if (memcmp(img + 0x20, ids, sizeof ids) != 0 || memcmp(img + RANE_HDR, ident, sizeof ident) != 0) {
        printf("%s: not an SL 3 image (VID/PID 1CC5/0001 in its header and its EEPROM identity)\n", name);
        return false;
    }
    printf("final image %s: firmware %u.%02u, CRC %08x\n", name, img[0x27], img[0x28], pcrc);
    if (boot->data) printf("bootstrap   %s: %lu bytes\n", boot->name.UTF8String, (unsigned long)boot->data.length);
    return true;
}

/* ---- the box on USB ---- */

typedef struct { io_service_t svc; int vid; bool firmware; uint64_t id; } box_t;

/* A device with the SL 3's IDs is running firmware (its own, or the bootstrap) if its descriptors
   carry strings: the EZ-USB's default device has none. */
static bool svc_has_strings(io_service_t s) {
    CFTypeRef name = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    if (!name) return false;
    CFRelease(name);
    return true;
}

static int find_vid_pid(int vid, int pid, box_t *out, int n, int max) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return n;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (n == max) { IOObjectRelease(s); continue; }
        out[n].svc = s;
        out[n].vid = vid;
        out[n].firmware = vid == SL3_VID && svc_has_strings(s);
        IORegistryEntryGetRegistryEntryID(s, &out[n].id);
        n++;
    }
    IOObjectRelease(it);
    return n;
}

/* Every attached SL 3, with or without firmware, plus any FX2 with a blank EEPROM. */
static int find_boxes(box_t *out, int max) {
    int n = find_vid_pid(SL3_VID, SL3_PID, out, 0, max);
    return find_vid_pid(FX2_DEFAULT_VID, FX2_DEFAULT_PID, out, n, max);
}

static void release_boxes(box_t *b, int n) { for (int i = 0; i < n; i++) IOObjectRelease(b[i].svc); }

/* ---- stage 1: load the bootstrap into RAM over EP0 ---- */

static bool fx2_request(IOUSBHostDevice *dev, uint8_t type, uint16_t value, NSMutableData *buf, const char *what) {
    IOUSBDeviceRequest r = { .bmRequestType = type, .bRequest = FX2_REQ_RAM, .wValue = value, .wIndex = 0, .wLength = (uint16_t)buf.length };
    NSError *e = nil; NSUInteger n = 0;
    if (![dev sendDeviceRequest:r data:buf bytesTransferred:&n completionTimeout:2.0 error:&e] || n != buf.length) {
        printf("%s (wValue 0x%04x): control transfer failed: %s (%lu/%lu bytes)\n", what, value,
               e ? e.localizedDescription.UTF8String : "short transfer", (unsigned long)n, (unsigned long)buf.length);
        return false;
    }
    return true;
}

/* Halt the 8051, write the bootstrap into RAM and read it back, then let the 8051 run it. */
static bool stage1(io_service_t svc, NSData *boot) {
    dispatch_queue_t q = dispatch_queue_create("sl3flash.stage1", DISPATCH_QUEUE_SERIAL);
    NSError *e = nil;
    IOUSBHostDevice *dev = nil;
    for (int attempt = 0; attempt < 10 && !dev; attempt++) {   /* in case another client is just letting go */
        dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:q error:&e interestHandler:nil];
        if (!dev) usleep(300000);
    }
    if (!dev) { printf("cannot open the box: %s\n", e.localizedDescription.UTF8String); return false; }

    const uint8_t *img = boot.bytes;
    size_t len = boot.length;
    bool ok = false;
    NSMutableData *one = [NSMutableData dataWithLength:1];
    ((uint8_t *)one.mutableBytes)[0] = 1;
    if (!fx2_request(dev, 0x40, FX2_CPUCS, one, "halt 8051")) goto done;
    for (size_t off = 0; off < len; off += RAM_CHUNK) {
        size_t n = (len - off < RAM_CHUNK) ? len - off : RAM_CHUNK;
        if (!fx2_request(dev, 0x40, (uint16_t)off, [NSMutableData dataWithBytes:img + off length:n], "write RAM")) goto done;
    }
    for (size_t off = 0; off < len; off += RAM_CHUNK) {
        size_t n = (len - off < RAM_CHUNK) ? len - off : RAM_CHUNK;
        NSMutableData *d = [NSMutableData dataWithLength:n];
        if (!fx2_request(dev, 0xC0, (uint16_t)off, d, "read RAM")) goto done;
        if (memcmp(d.bytes, img + off, n) != 0) { printf("bootstrap RAM verify failed at 0x%04zx\n", off); goto done; }
    }
    printf("bootstrap written to RAM and verified; starting it\n");
    ((uint8_t *)one.mutableBytes)[0] = 0;
    if (!fx2_request(dev, 0x40, FX2_CPUCS, one, "run 8051"))
        printf("(the run request did not complete cleanly; the box may already be restarting)\n");
    ok = true;
done:
    [dev destroy];
    return ok;
}

/* ---- the EEPROM, through the driver ---- */

/* Poll command 0x01 until the box answers through the driver. The driver lists its device only
   once it has opened a box, so the device is looked up again each time. */
static bool wait_for_answer(AudioObjectID *hal, double seconds, uint8_t *maj, uint8_t *min) {
    for (int i = 0; i < (int)(seconds * 4); i++) {
        *hal = sl3h_find_device();
        if (*hal != kAudioObjectUnknown && sl3h_version(*hal, maj, min)) return true;
        usleep(250000);
    }
    return false;
}

static bool read_eeprom(AudioObjectID hal, uint8_t *buf, uint32_t len, const char *what) {
    printf("%s", what); fflush(stdout);
    for (uint32_t a = 0; a < len; a += SL3_EEPROM_BLOCK) {
        if (!sl3h_eeprom_read(hal, (uint16_t)a, buf + a)) { printf("\nEEPROM read failed at 0x%04x\n", a); return false; }
        if ((a & 0xFFF) == 0) { printf("."); fflush(stdout); }
    }
    printf(" done\n");
    return true;
}

/* The whole EEPROM, before anything is written, into sl3-eeprom-backup-<date>.bin here. */
static bool save_backup(const uint8_t *eeprom) {
    char name[64];
    time_t t = time(NULL);
    strftime(name, sizeof name, "sl3-eeprom-backup-%Y%m%d-%H%M%S.bin", localtime(&t));
    FILE *f = fopen(name, "wb");
    if (!f || fwrite(eeprom, 1, SL3_EEPROM_SIZE, f) != SL3_EEPROM_SIZE) {
        printf("cannot write the EEPROM backup %s; nothing written to the box\n", name);
        if (f) fclose(f);
        return false;
    }
    fclose(f);
    printf("saved the EEPROM as it was to %s\n", name);
    return true;
}

/* 0x17, then every block written and checked against the box's own read-back, then the whole image
   range read again and compared with the image. Leaves byte 0 at 0xC0 (not bootable). */
static bool program(AudioObjectID hal, const uint8_t *pay) {
    uint8_t req[SL3_REPORT] = { OP_BEGIN }, reply[SL3_REPORT];
    if (!sl3h_command(hal, req, reply)) { printf("begin (0x17) was not acknowledged; nothing written\n"); return false; }
    printf("EEPROM marked not bootable (0x17); writing 0x%x bytes", IMAGE_LEN);
    fflush(stdout);
    for (uint32_t a = 0; a < IMAGE_LEN; a += SL3_EEPROM_BLOCK) {
        uint8_t rb[SL3_EEPROM_BLOCK];
        if (!sl3h_eeprom_write(hal, (uint16_t)a, pay + a, rb)) { printf("\nwrite failed at 0x%04x\n", a); return false; }
        if (memcmp(rb, pay + a, SL3_EEPROM_BLOCK) != 0) { printf("\nwrite at 0x%04x read back different bytes\n", a); return false; }
        if ((a & 0xFFF) == 0) { printf("."); fflush(stdout); }
    }
    printf(" done\n");

    uint8_t *buf = malloc(IMAGE_LEN);
    bool ok = read_eeprom(hal, buf, IMAGE_LEN, "re-reading the image range");
    if (ok) {
        for (uint32_t i = 0; i < IMAGE_LEN; i++) {
            if (buf[i] != pay[i]) {
                printf("verify failed at 0x%04x: image %02x, EEPROM %02x\n", i, pay[i], buf[i]);
                ok = false;
                break;
            }
        }
    }
    free(buf);
    if (ok) printf("EEPROM matches the image\n");
    return ok;
}

/* 0x16, then wait for the box to drop off the bus and come back running the image's firmware. */
static bool finalize(AudioObjectID hal, const uint8_t *final_hdr) {
    box_t b[4];
    int n = find_boxes(b, 4);
    uint64_t old_id = n ? b[0].id : 0;
    release_boxes(b, n);

    uint8_t req[SL3_REPORT] = { OP_FINALIZE }, reply[SL3_REPORT];
    if (sl3h_command(hal, req, reply)) printf("EEPROM marked bootable (0x16); the box is restarting\n");
    else printf("0x16 was not acknowledged; waiting to see whether the box restarts anyway\n");

    /* The box disconnects, waits 1 s, resets, boots its firmware and DSP, then enumerates again. */
    bool back = false;
    for (int i = 0; i < 300 && !back; i++) {
        usleep(100000);
        n = find_boxes(b, 4);
        for (int k = 0; k < n; k++) {
            if (b[k].id == old_id) continue;
            if (b[k].firmware) back = true;
            else { printf("the box restarted with no firmware running\n"); release_boxes(b, n); return false; }
        }
        release_boxes(b, n);
    }
    if (!back) { printf("the box did not come back within 30 s\n"); return false; }

    uint8_t maj, min;
    if (!wait_for_answer(&hal, 15, &maj, &min)) { printf("the box is back but does not answer through the driver\n"); return false; }
    printf("the box is running firmware %u.%02u\n", maj, min);
    if (maj != final_hdr[0x27] || min != final_hdr[0x28]) {
        printf("expected %u.%02u from the image\n", final_hdr[0x27], final_hdr[0x28]);
        return false;
    }
    return true;
}

/* ---- main ---- */

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *dir = kDefaultDir;
    bool dry = false, force = false, blank_ok = false;
    int waitsecs = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dry-run")) dry = true;
        else if (!strcmp(argv[i], "--force")) force = true;
        else if (!strcmp(argv[i], "--firmware") && i + 1 < argc) dir = argv[++i];
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) waitsecs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--blank-fx2")) blank_ok = true;
        else { fprintf(stderr, "usage: %s [--firmware DIR] [--force] [--dry-run] [--wait SECONDS] [--blank-fx2]\n", argv[0]); return 2; }
    }

    image_t final = {0}, boot = {0};
    if (!load_images(dir, &final, &boot)) return 1;
    const uint8_t *hdr = final.data.bytes, *pay = hdr + RANE_HDR;

    /* Find the box: one with no firmware shows up on USB only; a running box answers 0x01 through
       the driver (the firmware 2.50, or the bootstrap 2.25 if a previous run loaded it). */
    box_t b[4];
    int n = 0;
    uint8_t maj = 0, min = 0;
    bool running = false;
    AudioObjectID hal = kAudioObjectUnknown;
    for (int i = 0; ; i++) {
        n = find_boxes(b, 4);
        if (n > 1) { printf("%d SL 3s (or blank FX2s) are connected; connect only the one to flash\n", n); release_boxes(b, n); return 1; }
        if (n == 1 && b[0].vid == FX2_DEFAULT_VID && !blank_ok) {
            printf("a Cypress FX2 with a blank EEPROM (04b4:8613) is connected. It may be an SL 3 whose EEPROM is\n"
                   "blank, or any other device built on an FX2: if you are sure it is the SL 3, run again with --blank-fx2\n");
            release_boxes(b, n);
            return 1;
        }
        if (n == 1 && !b[0].firmware) break;
        hal = sl3h_find_device();
        if (n == 1 && hal != kAudioObjectUnknown && sl3h_version(hal, &maj, &min)) { running = true; break; }
        release_boxes(b, n); n = 0;
        if (i >= waitsecs * 4) {
            printf(hal == kAudioObjectUnknown ? "no SL 3 found (or the SL 3 audio driver, which sl3flash sends its commands through, is not loaded)\n"
                                              : "no SL 3 found\n");
            return 1;
        }
        if (i == 0) printf("waiting up to %d s for an SL 3...\n", waitsecs);
        usleep(250000);
    }

    if (running) {
        release_boxes(b, n);
        bool loader = (maj << 8 | min) == BOOTSTRAP_VERSION;
        printf("SL 3 running %s %u.%02u\n", loader ? "Rane's firmware loader (the bootstrap)" : "firmware", maj, min);
    } else {
        printf("SL 3 with no firmware running (%04x:%04x, no strings)\n", b[0].vid, b[0].vid == SL3_VID ? SL3_PID : FX2_DEFAULT_PID);
        if (!boot.data) { printf("no bootstrap image in %s; it is needed for a box in this state\n", dir); release_boxes(b, n); return 1; }
        if (dry) { printf("dry run: would load the bootstrap, then program the EEPROM\n"); release_boxes(b, n); return EXIT_WOULD_WRITE; }
        bool ok = stage1(b[0].svc, boot.data);
        release_boxes(b, n);
        if (!ok) return 1;
        if (!wait_for_answer(&hal, 20, &maj, &min)) { printf("the bootstrap did not answer through the driver within 20 s (is the SL 3 driver installed?)\n"); return 1; }
        printf("bootstrap running (reports %u.%02u)\n", maj, min);
    }
    if (sl3h_is_streaming(hal)) { printf("the SL 3 is in use for audio; stop playback (or quit the app using it) and try again\n"); return 1; }

    /* Read the whole EEPROM: the image range decides what to do; all of it is the backup. */
    uint8_t *cur = malloc(SL3_EEPROM_SIZE);
    if (!read_eeprom(hal, cur, SL3_EEPROM_SIZE, "reading the EEPROM")) { free(cur); return 1; }
    bool same = memcmp(cur + 1, pay + 1, IMAGE_LEN - 1) == 0;
    uint8_t boot_hdr = cur[0];
    printf("EEPROM %s the image; boot byte 0x%02x (%s)\n", same ? "matches" : "differs from", boot_hdr,
           boot_hdr == HDR_BOOT ? "bootable" : boot_hdr == HDR_NOBOOT ? "not bootable" : "invalid");

    if (same && !force && running && boot_hdr == HDR_BOOT && (maj << 8 | min) != BOOTSTRAP_VERSION) {
        printf("nothing to do (--force rewrites it anyway)\n");
        free(cur);
        return 0;
    }
    if (dry) {
        printf("dry run: would %s\n", same && !force ? "mark the EEPROM bootable" : "program the EEPROM");
        free(cur);
        return EXIT_WOULD_WRITE;
    }
    bool saved = save_backup(cur);
    free(cur);
    if (!saved) return 1;
    if (same && !force) printf("the EEPROM already holds the image; only marking it bootable\n");
    else if (!program(hal, pay)) {
        printf("FAILED before the EEPROM was marked bootable. The box %s; run sl3flash again.\n",
               running ? "keeps running until it is power-cycled, then starts with no firmware"
                       : "runs the bootstrap until it is power-cycled, then starts with no firmware");
        return 1;
    }
    if (!finalize(hal, hdr)) return 1;
    printf("done\n");
    return 0;
  }
}
