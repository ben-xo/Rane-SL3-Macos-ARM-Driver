// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Sl3Api.m — Universal (arm64 + x86_64) replacement for /Library/Frameworks/Sl3Api.framework
 *
 * Rane's Sl3Api is the library Serato DJ Pro 2.5.5, Rane's "SL 3 Audio Control Panel" and its
 * Sl3SettingsService load to talk to an SL 3. This one implements the same exported functions, with
 * the same arguments, results and return codes as Rane's 2.0.1f2 (compared with its disassembly;
 * docs/SL3-AUDIO-ENGINE.md, "Sl3Api"), on top of the SL3Device CoreAudio HAL plug-in's custom
 * properties:
 *   'sl3h'  write a 64-byte HID command; the next read returns the box's reply
 *   'sl3s'  read the driver's status (SL3StatusPacket)
 *   'sl3q'  read this process's queued reports (the box's 0x34 / 0x38 / 0x39 and the driver's events)
 * Without the plug-in there is no path to the box: commands fail.
 *
 * Return codes, as Rane's: 0 = done, SL3_ERR_REPLY = the reply was for another command,
 * SL3_ERR_PARAM = unknown parameter id, SL3_ERR_IO = no box, no driver or no reply, SL3_ERR_BAD_ARG =
 * a handle that isn't open, or a bad argument. (Rane's SL2Api has a separate "not connected" code;
 * Rane's Sl3Api reports that as SL3_ERR_IO.) Callbacks are called on this library's own serial queue,
 * as Rane's are on its own monitor thread.
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <os/log.h>

#define VID 0x1cc5
#define PID 0x0001

#define kSL3PropHIDCommand  'sl3h'
#define kSL3PropStatus      'sl3s'
#define kSL3PropUnsolQueue  'sl3q'

enum {
    SL3_OK          = 0,
    SL3_ERR_REPLY   = 1,
    SL3_ERR_PARAM   = 2,
    SL3_ERR_IO      = 4,
    SL3_ERR_BAD_ARG = 8,
};

/* The box's HID protocol (docs/SL3-COMMANDS.md): one 64-byte report per command and reply,
   [0] = command, [1..4] = tag, [5..] = arguments / results. */
enum {
    HID_REPORT_LEN          = 64,
    HID_MAX_ARGS            = HID_REPORT_LEN - 5,
    SL3_CONTROLS_LEN        = 22,     /* the audio control block (0x32 / 0x33) */
    SL3_CMD_VERSION         = 0x01,   /* reply [5] major, [6] minor */
    SL3_CMD_STATUS          = 0x0a,   /* reply [5] */
    SL3_CMD_GET_RATE        = 0x30,   /* reply [5..6] rate, big-endian */
    SL3_CMD_GET_CONTROLS    = 0x32,   /* reply [5..26] the control block */
    SL3_CMD_SET_CONTROLS    = 0x33,   /* [5] offset, [6] count, [7..] values */
    SL3_CMD_GET_OVERLOAD    = 0x35,   /* reply [5..10] */
    SL3_CMD_CHALLENGE       = 0x37,   /* [5..12] challenge -> reply [5..12] answer */
    SL3_REPORT_OVERLOAD     = 0x34,   /* the box's unsolicited reports: [5..10] */
    SL3_REPORT_PHONO        = 0x38,   /*   [5..7] LINE/PHONO switches: aux, left, right */
    SL3_REPORT_THRU         = 0x39,   /*   [5..8] output source: aux, left, right, ? (0 = thru) */
};

/* The driver's status ('sl3s'); must match SL3Device.m */
typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];
    uint8_t  thru[4];
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;
    uint32_t debug_build;
    uint32_t in_safety_us;
    uint32_t early_read;
    uint32_t hub_depth;
    uint64_t in_dropouts;
    uint8_t  overload[8];
} SL3StatusPacket;

/* Rane's API types */
typedef struct { uint32_t w[4]; } sl3_version;
typedef struct { uint8_t b[6]; } sl3_overload_status_data;
typedef struct { uint8_t aux, left, right; } sl3_phonoswitch_status_data;     /* != 0: phono */
typedef struct { uint8_t aux, left, right, unknown; } sl3_thrustate_status_data;   /* 0: analogue thru */
typedef struct { uint32_t status; uint32_t reserved; } sl3_usb_port_status_t; /* status 1: connected */
typedef struct { uint8_t percent; } sl3_firmware_status_data;

typedef void (*overload_cb_t)(sl3_overload_status_data *);
typedef void (*phono_cb_t)(sl3_phonoswitch_status_data *);
typedef void (*thru_cb_t)(sl3_thrustate_status_data *);
typedef void (*port_cb_t)(sl3_usb_port_status_t *);

/* Open handles, as Rane's: 1, 2, 3, ... in turn, never reused; each with its own callbacks. */
typedef struct Client {
    uintptr_t handle;
    overload_cb_t overload_cb;
    phono_cb_t phono_cb;
    thru_cb_t thru_cb;
    port_cb_t port_cb;
    struct Client *next;
} Client;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;     /* the clients (callbacks are called outside it) */
static pthread_mutex_t g_cmd_lock = PTHREAD_MUTEX_INITIALIZER; /* one command at a time per process */
static Client  *g_clients;
static uintptr_t g_next_handle = 1;
static int      g_open_count;
static int      g_initial_buffer_ms = -1;   /* sl3_open_private's value, from the first open in the process */
static bool     g_instance_made;            /* the first open has happened */
static int      g_buffer_ms = 4;            /* the latency slider value; see sl3_set_buffer_millisecs */
static uint32_t g_seq = 1;
static dispatch_queue_t  g_poll_q;
static dispatch_source_t g_poll_timer;
static _Atomic bool g_was_connected;        /* box connected at the last poll */

/* Every exported call is logged at debug level with its result, plus what was sent to and received
   from the box, so a client's use of the API can be followed without a debugger:
     log stream --level debug --predicate 'subsystem == "com.rane.sl3api"' */
static os_log_t api_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.rane.sl3api", "api"); });
    return log;
}
#define TRACE(fmt, ...) os_log_debug(api_log(), "%{public}s" fmt, __func__, ##__VA_ARGS__)
#define RET(e) ({ int ret_ = (e); TRACE(" -> %d", ret_); ret_; })

/* The open client for handle h, or NULL (call with g_lock held). */
static Client *client_locked(void *h) {
    for (Client *c = g_clients; c; c = c->next) if (h && c->handle == (uintptr_t)h) return c;
    return NULL;
}
static bool handle_ok(void *h) {
    pthread_mutex_lock(&g_lock);
    bool ok = client_locked(h) != NULL;
    pthread_mutex_unlock(&g_lock);
    return ok;
}

/* ============================================================================
 * The driver: its device, status and properties
 * ============================================================================ */

/* The SL 3's CoreAudio device, cached; the cache is dropped whenever the system's device list
   changes (the device only exists while a box is attached). */
static _Atomic AudioObjectID g_dev = kAudioObjectUnknown;
static OSStatus devices_changed(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *c) {
    atomic_store(&g_dev, kAudioObjectUnknown);
    return 0;
}

static AudioObjectID find_hal_device(void) {
    /* Once per process: listen for changes to the device list, which drop the cache. */
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectPropertyAddress da = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &da, devices_changed, NULL);
    });
    /* Use the cached device while there is one. */
    AudioObjectID dev = atomic_load(&g_dev);
    if (dev != kAudioObjectUnknown) return dev;
    /* Otherwise look it up by the HAL plug-in's device UID, and cache it. */
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl3.hal.device");
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev) != noErr) return kAudioObjectUnknown;
    atomic_store(&g_dev, dev);
    return dev;
}

static bool hal_get_status(SL3StatusPacket *outSt) {
    /* Without the driver's device there is no status. */
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return false;
    /* Read the status property, which the driver returns as a CFData. */
    AudioObjectPropertyAddress a = { kSL3PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    bool ok = false;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        /* Copy what the driver sent (zero-filling the rest if it is shorter); it counts as a status
           if it holds every field before boot_mode. */
        memset(outSt, 0, sizeof *outSt);
        CFIndex n = CFDataGetLength(d);
        memcpy(outSt, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof *outSt ? n : (CFIndex)sizeof *outSt));
        ok = n >= (CFIndex)offsetof(SL3StatusPacket, boot_mode);
        CFRelease(d);
    }
    return ok;
}

/* The driver has the box open. */
static bool box_connected(void) {
    SL3StatusPacket st;
    return hal_get_status(&st) && st.connected;
}

/* A box with the SL 3's vendor and product IDs is in the USB registry. */
static bool in_usb_registry(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    /* Any match means a box is attached. */
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s) { IOObjectRelease(s); return true; }
    return false;
}

/* The SL 3 HAL plug-in is loaded in coreaudiod. */
static bool driver_loaded(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateBundleIDToPlugIn, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef bundle = CFSTR("io.github.pepeleedj.sl3device");
    AudioObjectID plugin = kAudioObjectUnknown;
    UInt32 sz = sizeof plugin;
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof bundle, &bundle, &sz, &plugin) == noErr &&
           plugin != kAudioObjectUnknown;
}

/* The driver's device, ready for commands (it has opened the box). Just after the box is plugged
   in, it is in the USB registry before the driver has opened it and listed its device: usually
   tens of milliseconds, about a second if macOS refuses the first open. A client that watches USB
   itself can call in that window (Serato DJ Pro 2.5.5 opens the library when it sees the box on
   USB, makes its hardware check once and ignores the result), so while the box is in the registry
   and the driver is loaded, wait for the device, up to READY_WAIT_MS. */
#define READY_WAIT_MS 2000
#define READY_POLL_MS 20
static AudioObjectID ready_hal_device(void) {
    for (int waited = 0; ; waited += READY_POLL_MS) {
        /* Ready: the device is listed and the driver reports the box open. */
        AudioObjectID dev = find_hal_device();
        SL3StatusPacket st;
        bool have_st = dev != kAudioObjectUnknown && hal_get_status(&st);
        if (have_st && st.connected) return dev;
        /* Not ready, and not about to be (no box, a box with no firmware, which the driver never opens,
           or no driver to open it), or waited long enough. */
        if (waited >= READY_WAIT_MS || (have_st && st.boot_mode) || !in_usb_registry() || !driver_loaded())
            return kAudioObjectUnknown;
        if (waited == 0) TRACE(": the box is attached but the driver has not opened it yet: waiting");
        usleep(READY_POLL_MS * 1000);
    }
}

/* Send one HID command through the driver and get the box's reply, as Rane's SendHidRequest:
   SL3_OK (reply_out holds the reply), SL3_ERR_REPLY (the reply's command byte isn't cmd) or
   SL3_ERR_IO (no box, no driver, or no reply). */
static int send_hid_cmd(uint8_t cmd, const uint8_t *args, size_t nargs, uint8_t *reply_out) {
    /* No driver device (after waiting for one that is on its way) means no box; otherwise take the
       lock so each command gets its own reply. */
    AudioObjectID dev = ready_hal_device();
    if (dev == kAudioObjectUnknown) return SL3_ERR_IO;
    pthread_mutex_lock(&g_cmd_lock);

    /* Build the request: the driver sends it when it is written, and the next read returns the
       reply with our tag. */
    uint8_t req[HID_REPORT_LEN] = {0};
    req[0] = cmd;
    uint32_t seq = g_seq++;
    memcpy(req + 1, &seq, 4);
    if (args && nargs > 0) memcpy(req + 5, args, nargs > HID_MAX_ARGS ? HID_MAX_ARGS : nargs);
    AudioObjectPropertyAddress a = { kSL3PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, HID_REPORT_LEN);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);

    /* Read the reply back. */
    int result = SL3_ERR_IO;
    if (st == noErr) {
        CFDataRef out = NULL;
        UInt32 sz = sizeof(CFDataRef);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) == noErr && out) {
            /* Copy at most one report, and accept it only if it carries our tag. */
            uint8_t reply[HID_REPORT_LEN] = {0};
            CFIndex n = CFDataGetLength(out);
            memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < HID_REPORT_LEN ? n : HID_REPORT_LEN));
            CFRelease(out);
            if (memcmp(reply + 1, req + 1, 4) == 0) {
                if (reply_out) memcpy(reply_out, reply, HID_REPORT_LEN);
                result = reply[0] == cmd ? SL3_OK : SL3_ERR_REPLY;
            }
        }
    }
    pthread_mutex_unlock(&g_cmd_lock);
    TRACE(": cmd 0x%02x -> %d, reply %{public}.12P", cmd, result, reply_out ? reply_out : req);
    return result;
}

/* ============================================================================
 * Reports and events, polled from the driver and passed to every client's callbacks
 * ============================================================================ */

/* The open handles' callbacks, copied under g_lock so they can be called without it: a callback may
   call back into the API (Rane's lock is recursive, so that works with Rane's too), or wait on a
   thread that is calling into it. A handle closed after the copy may get one last call. */
#define MAX_CALLBACKS 64
typedef struct { overload_cb_t overload; phono_cb_t phono; thru_cb_t thru; port_cb_t port; } Callbacks;
static int copy_callbacks(Callbacks out[MAX_CALLBACKS]) {
    int n = 0;
    pthread_mutex_lock(&g_lock);
    for (Client *c = g_clients; c && n < MAX_CALLBACKS; c = c->next)
        out[n++] = (Callbacks){ c->overload_cb, c->phono_cb, c->thru_cb, c->port_cb };
    pthread_mutex_unlock(&g_lock);
    return n;
}

static void dispatch_report(const uint8_t pkt[HID_REPORT_LEN]) {
    /* As Rane's HandleUnsolicitedData: the report's payload goes to the matching callback of every
       open handle. */
    Callbacks cb[MAX_CALLBACKS];
    int n = copy_callbacks(cb);
    for (int i = 0; i < n; i++) {
        if (pkt[0] == SL3_REPORT_OVERLOAD && cb[i].overload) {
            sl3_overload_status_data o;
            memcpy(o.b, pkt + 5, sizeof o.b);
            cb[i].overload(&o);
        } else if (pkt[0] == SL3_REPORT_PHONO && cb[i].phono) {
            sl3_phonoswitch_status_data p = { pkt[5], pkt[6], pkt[7] };
            cb[i].phono(&p);
        } else if (pkt[0] == SL3_REPORT_THRU && cb[i].thru) {
            sl3_thrustate_status_data t = { pkt[5], pkt[6], pkt[7], pkt[8] };
            cb[i].thru(&t);
        }
    }
    TRACE(": report %{public}.12P", pkt);
}

/* Call every client's port-status callback: {1, 0} when the box appears, {0, 0} when it goes. */
static void dispatch_port_status(bool connected) {
    Callbacks cb[MAX_CALLBACKS];
    int n = copy_callbacks(cb);
    for (int i = 0; i < n; i++) {
        if (!cb[i].port) continue;
        sl3_usb_port_status_t ps = { connected ? 1 : 0, 0 };
        cb[i].port(&ps);
    }
    TRACE(": port status {%d, 0}", connected ? 1 : 0);
}

/* Every 15 ms on g_poll_q: notice the box coming and going, then pass on this process's queued
   reports. */
static void poll_driver(void) {
    /* Connected or not; tell the clients when that changes. */
    AudioObjectID dev = find_hal_device();
    bool connected = dev != kAudioObjectUnknown && box_connected();
    if (connected != atomic_exchange(&g_was_connected, connected)) dispatch_port_status(connected);
    if (!connected) return;

    /* This process's reports since the last poll: a run of 64-byte reports, each passed on. */
    AudioObjectPropertyAddress a = { kSL3PropUnsolQueue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        CFIndex len = CFDataGetLength(d);
        const uint8_t *bytes = CFDataGetBytePtr(d);
        for (CFIndex off = 0; off + HID_REPORT_LEN <= len; off += HID_REPORT_LEN) dispatch_report(bytes + off);
        CFRelease(d);
    }
}

/* Start polling (from the first open); sl3_close stops it again with the last handle. The state at
   the start is recorded without a callback, as Rane's connects to an attached box inside the first
   open, before a callback can be set. */
static void poll_start(void) {
    if (g_poll_timer) return;
    if (!g_poll_q) g_poll_q = dispatch_queue_create("com.rane.sl3api.poll", DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_was_connected, box_connected());
    g_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_poll_q);
    dispatch_source_set_timer(g_poll_timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC), 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_poll_timer, ^{ poll_driver(); });
    dispatch_resume(g_poll_timer);
}

static void poll_stop(void) {
    if (!g_poll_timer) return;
    dispatch_source_cancel(g_poll_timer);
    g_poll_timer = nil;
}

/* ============================================================================
 * Exported functions, as Rane's
 * ============================================================================ */

#define EXPORT __attribute__((visibility("default")))

/* A new handle. Only the first open in the process sets the initial buffer size, as Rane's. */
static void *open_handle(int initial_buffer_ms) {
    Client *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    pthread_mutex_lock(&g_lock);
    if (!g_instance_made) { g_instance_made = true; g_initial_buffer_ms = initial_buffer_ms; }
    c->handle = g_next_handle++;
    c->next = g_clients;
    g_clients = c;
    if (g_open_count++ == 0) poll_start();
    TRACE(": handle %lu, open handles %d", (unsigned long)c->handle, g_open_count);
    pthread_mutex_unlock(&g_lock);
    return (void *)c->handle;
}

EXPORT void *sl3_open(void) { return open_handle(-1); }

EXPORT void sl3_close(void *h) {
    pthread_mutex_lock(&g_lock);
    for (Client **p = &g_clients; *p; p = &(*p)->next) {
        if ((*p)->handle != (uintptr_t)h) continue;
        Client *c = *p;
        *p = c->next;
        free(c);
        if (--g_open_count == 0) poll_stop();
        break;
    }
    TRACE(": open handles %d", g_open_count);
    pthread_mutex_unlock(&g_lock);
}

EXPORT int sl3_get_api_version(sl3_version *v) {
    if (!v) return RET(SL3_ERR_BAD_ARG);
    *v = (sl3_version){ { 2, 0, 1, 2 } };
    return RET(SL3_OK);
}

/* Rane's reports its kernel extension's version, {2, 0, 1, 2}: the same here, with the box
   attached (Rane's kernel extension answered only then). */
EXPORT int sl3_get_driver_version(void *h, sl3_version *v) {
    if (!handle_ok(h) || !v) return RET(SL3_ERR_BAD_ARG);
    if (!box_connected()) return RET(SL3_ERR_IO);
    *v = (sl3_version){ { 2, 0, 1, 2 } };
    return RET(SL3_OK);
}

EXPORT int sl3_get_vendor_id(void *h, int *vid) {
    if (!handle_ok(h) || !vid) return RET(SL3_ERR_BAD_ARG);
    if (!box_connected()) return RET(SL3_ERR_IO);
    *vid = VID;
    return RET(SL3_OK);
}
EXPORT int sl3_get_product_id(void *h, int *pid) {
    if (!handle_ok(h) || !pid) return RET(SL3_ERR_BAD_ARG);
    if (!box_connected()) return RET(SL3_ERR_IO);
    *pid = PID;
    return RET(SL3_OK);
}

/* Ask the box (0x01): words 0 and 1 are the major and minor version; words 2 and 3 are left as
   they were, as Rane's leaves them. */
EXPORT int sl3_get_firmware_version(void *h, sl3_version *v) {
    if (!handle_ok(h) || !v) return RET(SL3_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_VERSION, NULL, 0, r);
    if (e) return RET(e);
    v->w[0] = r[5];
    v->w[1] = r[6];
    return RET(SL3_OK);
}

/* The firmware Rane's framework embeds is v2.50. */
EXPORT int sl3_get_firmware_embedded_version(void *h, sl3_version *v) {
    if (!handle_ok(h) || !v) return RET(SL3_ERR_BAD_ARG);
    *v = (sl3_version){ { 2, 50, 0, 0 } };
    return RET(SL3_OK);
}

/* Whether the box is in its EZ-USB bootloader (Rane's asked its kernel extension). Always 0:
   reporting 1 would start the control panel's automatic firmware update, which is deliberately not
   implemented here. The return code is what Rane's control panel uses to tell whether the box is
   connected: SL3_ERR_IO without one. */
EXPORT int sl3_is_C0_device(void *h, int *c0) {
    if (!handle_ok(h) || !c0) return RET(SL3_ERR_BAD_ARG);
    if (!box_connected()) return RET(SL3_ERR_IO);
    *c0 = 0;
    return RET(SL3_OK);
}

/* The box's status byte (0x0a, reply [5]). */
EXPORT int sl3_get_status(void *h, uint8_t *status) {
    if (!handle_ok(h) || !status) return RET(SL3_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_STATUS, NULL, 0, r);
    if (e) return RET(e);
    *status = r[5];
    return RET(SL3_OK);
}

/* The 22-byte audio control block (0x32): bytes offset..offset+len-1 of it. See docs/SL3-COMMANDS.md
   for what the bytes are; Serato reads a deck's output source (8 aux, 14 left, 20 right). */
EXPORT int sl3_get_audio_controls(void *h, int offset, uint8_t *buf, int len) {
    if (!handle_ok(h) || !buf || len <= 0 || offset < 0 || offset > SL3_CONTROLS_LEN - 1 || offset + len > SL3_CONTROLS_LEN)
        return RET(SL3_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_GET_CONTROLS, NULL, 0, r);
    if (e) return RET(e);
    memcpy(buf, r + 5 + offset, (size_t)len);
    TRACE(": [%d..%d] %{public}.*P", offset, offset + len - 1, len, buf);
    return RET(SL3_OK);
}

/* Write bytes offset..offset+len-1 of the control block (0x33: offset, count, values, zero-padded to
   a full report, as Rane's). Serato sets a deck's output source this way: 1 = USB audio, 0 = thru. */
EXPORT int sl3_set_audio_controls(void *h, int offset, const uint8_t *buf, int len) {
    if (!handle_ok(h) || !buf || len <= 0 || offset < 0 || offset > SL3_CONTROLS_LEN - 1 || offset + len > SL3_CONTROLS_LEN)
        return RET(SL3_ERR_BAD_ARG);
    TRACE(": [%d..%d] %{public}.*P", offset, offset + len - 1, len, buf);
    uint8_t args[HID_MAX_ARGS] = {0};
    args[0] = (uint8_t)offset;
    args[1] = (uint8_t)len;
    memcpy(args + 2, buf, (size_t)len);
    return RET(send_hid_cmd(SL3_CMD_SET_CONTROLS, args, sizeof args, NULL));
}

/* Parameter 0 is the sample rate: read from the box (0x30, [5..6] big-endian). */
EXPORT int sl3_get_parameter(void *h, int id, int *value) {
    if (!handle_ok(h) || !value) return RET(SL3_ERR_BAD_ARG);
    if (id != 0) return RET(SL3_ERR_PARAM);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_GET_RATE, NULL, 0, r);
    if (e) return RET(e);
    *value = (r[5] << 8) | r[6];
    return RET(SL3_OK);
}

/* Set parameter 0, the sample rate, through CoreAudio: the HAL plug-in then changes the HAL's rate
   and the box's together (a rate set only on the box would leave the HAL rendering at the old
   one). Rane's asked its kernel extension, which did the same. */
EXPORT int sl3_set_parameter(void *h, int id, int value) {
    if (!handle_ok(h)) return RET(SL3_ERR_BAD_ARG);
    if (id != 0) return RET(SL3_ERR_PARAM);
    if (value != 44100 && value != 48000) return RET(SL3_ERR_BAD_ARG);
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return RET(SL3_ERR_IO);
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 fsr = (Float64)value;
    return RET(AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &fsr) == noErr ? SL3_OK : SL3_ERR_IO);
}

/* The latency slider in Rane's "SL 3 Audio Control Panel" (kept at 4 ms by Rane's Sl3SettingsService).
   Rane's kernel extension used it as the USB buffer size; the HAL plug-in's playback latency is fixed
   (it does not depend on a buffer size), so a value is validated (1-50 ms) and kept, and reading it
   back gives the plug-in's real output latency plus safety offset, rounded up.
   Serato DJ Pro 2.5.5 doesn't call these: its own "USB buffer size" sets the CoreAudio IO buffer size
   (kAudioDevicePropertyBufferFrameSize), which the HAL owns, and tells neither Sl3Api nor the box. */
EXPORT int sl3_set_buffer_millisecs(void *h, int ms) {
    if (!h || ms < 1 || ms > 50 || !handle_ok(h)) return RET(SL3_ERR_BAD_ARG);
    if (!box_connected()) return RET(SL3_ERR_IO);
    g_buffer_ms = ms;
    return RET(SL3_OK);
}
EXPORT int sl3_get_buffer_millisecs(void *h, int *ms) {
    if (!h || !ms || !handle_ok(h)) return RET(SL3_ERR_BAD_ARG);
    /* Needs the driver's device. */
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown || !box_connected()) return RET(SL3_ERR_IO);
    /* Read the output latency and safety offset (in frames). */
    UInt32 lat = 0, safety = 0, sz = sizeof(UInt32);
    Float64 sr = 0;
    AudioObjectPropertyAddress la = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress sa = { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(dev, &la, 0, NULL, &sz, &lat);
    sz = sizeof(UInt32);
    AudioObjectGetPropertyData(dev, &sa, 0, NULL, &sz, &safety);
    /* Convert the frames to ms, rounded up; without a usable rate, give back the stored value. */
    sz = sizeof(Float64);
    if (AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &sr) != noErr || sr <= 0) { *ms = g_buffer_ms; return RET(SL3_OK); }
    *ms = (int)ceil((double)(lat + safety) * 1000.0 / sr);
    return RET(SL3_OK);
}

/* {status, 0}: 1 while the box is connected, as Rane's (which reads its own connection flag; the
   return is 0 either way). Serato DJ Pro 2.5.5 takes status as its "connected?". */
EXPORT int sl3_get_usb_port_status(void *h, sl3_usb_port_status_t *s) {
    if (!handle_ok(h) || !s) return RET(SL3_ERR_BAD_ARG);
    s->status = box_connected() ? 1 : 0;
    s->reserved = 0;
    return RET(SL3_OK);
}

/* The challenge Serato uses to check it is talking to genuine Rane hardware: send the 8-byte
   challenge with 0x37 and return the box's 8-byte answer. */
EXPORT int sl3_driver_timer(void *h, const uint8_t *in, int inlen, uint8_t *out, int outlen) {
    TRACE(": challenge %{public}.*P (%d bytes, answer buffer %d)", in && inlen > 0 && inlen <= HID_MAX_ARGS ? inlen : 0, in, inlen, outlen);
    if (!handle_ok(h) || !in || !out || inlen != 8 || outlen != 8) return RET(SL3_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_CHALLENGE, in, 8, r);
    if (e) return RET(e);
    memcpy(out, r + 5, 8);
    TRACE(": answer %{public}.*P", 8, out);
    return RET(SL3_OK);
}

/* The box's overload state (0x35, reply [5..10]). */
EXPORT int sl3_get_overload_status(void *h, sl3_overload_status_data *o) {
    if (!handle_ok(h) || !o) return RET(SL3_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL3_CMD_GET_OVERLOAD, NULL, 0, r);
    if (e) return RET(e);
    memcpy(o->b, r + 5, sizeof o->b);
    return RET(SL3_OK);
}

/* Callbacks, per handle: setting one replaces the handle's previous one; NULL clears it. */
#define SET_CALLBACK(field, type)                                   \
    pthread_mutex_lock(&g_lock);                                    \
    Client *c = client_locked(h);                                   \
    if (c) c->field = (type)cb;                                     \
    pthread_mutex_unlock(&g_lock);                                  \
    return RET(c ? SL3_OK : SL3_ERR_BAD_ARG);

EXPORT int sl3_set_overload_callback(void *h, void *cb)        { SET_CALLBACK(overload_cb, overload_cb_t) }
EXPORT int sl3_set_phonoswitch_callback(void *h, void *cb)     { SET_CALLBACK(phono_cb, phono_cb_t) }
EXPORT int sl3_set_thrustate_callback(void *h, void *cb)       { SET_CALLBACK(thru_cb, thru_cb_t) }
EXPORT int sl3_set_usb_port_status_callback(void *h, void *cb) { SET_CALLBACK(port_cb, port_cb_t) }

/* Firmware update and re-enumeration (Rane's sends 0x1a, which re-enumerates the box under another
   product ID) are deliberately not implemented: a client must never trigger them by accident. The
   update reports failure, so a caller doesn't take its firmware as updated. */
EXPORT int sl3_set_update_firmware(void *h, const uint8_t *image, uint32_t len, void *cb) {
    return RET(handle_ok(h) ? SL3_ERR_IO : SL3_ERR_BAD_ARG);
}
EXPORT int sl3_set_update_firmware_from_embedded(void *h, void *cb) {
    return RET(handle_ok(h) ? SL3_ERR_IO : SL3_ERR_BAD_ARG);
}
EXPORT int sl3_set_alt_product_id(void *h) {
    return RET(handle_ok(h) ? SL3_OK : SL3_ERR_BAD_ARG);
}

/* C++ entry points Rane's framework also exports */
EXPORT void *_Z8RaneOpenv(void)                 { return open_handle(-1); }
EXPORT void *_Z15RaneOpenPrivatei(int ms)       { return open_handle(ms); }
EXPORT void *_Z16sl3_open_privatei(int ms)      { return open_handle(ms); }
/* sl3_open_private's buffer size from the first open (-1 if it was sl3_open). */
EXPORT int _Z32sl3_get_last_buffer_millisecondsv(void) {
    pthread_mutex_lock(&g_lock);
    int ms = g_initial_buffer_ms;
    pthread_mutex_unlock(&g_lock);
    return ms;
}
EXPORT int _Z33sl3_private_last_connection_errorv(void) { return 0; }
