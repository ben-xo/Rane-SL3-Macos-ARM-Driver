/*
 * SL3Status.h — the driver's status packet ('sl3s'), for the Swift control panel. A C struct, so
 * Swift sees the same layout the driver writes; it must match SL3StatusPacket in plugin/SL3Device.m.
 */
#include <stdint.h>

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];       /* [Aux, Left, Right]: 1 = Phono, 0 = Line (one switch per deck on the box) */
    uint8_t  thru[4];        /* [Aux, Left, Right]: 1 = analogue thru, 0 = USB audio */
    uint8_t  port_a;         /* always 0 on the SL 3 (c.f. the SL 2's port status) */
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;      /* 1 = the box has no firmware running: no audio until it is restored */
    uint32_t debug_build;    /* 1 = the driver is a debug build (make plugin DEBUG=1) */
    /* Input health */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles in which input wasn't captured in time, since the device was
                                       set up (the box connected, or the input safety offset changed) */
    /* SL 3 only, after the fields shared with the SL 2's status (zero from a driver without them) */
    uint8_t  overload[6];           /* the box's six overload flags (HID 0x34 / 0x35) */
    uint8_t  ext_power;             /* control byte 21: the external power input */
    uint8_t  usb_state;             /* HID 0x0a: 2 = high speed (audio), 1 = full speed (no audio), 0 = unknown */
} SL3StatusPacket;
