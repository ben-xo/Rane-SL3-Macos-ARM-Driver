// sl3apitest: check Sl3Api the way Serato DJ Pro 2.5.5 uses it. Serato loads the framework from the
// path below and looks up seven functions; this loads it the same way, makes the same calls with
// Rane's signatures, and prints PASS or FAIL for each check.
//
//   make apitest
//   arch -x86_64 ./sl3apitest     Serato 2.5.5 is Intel-only, so this is the slice it loads
//   ./sl3apitest [path]           the arm64 slice, or another build of the framework
//
// Needs the driver installed and a box attached, with no audio playing: the test switches each
// deck between analogue thru and USB, and puts it back as it found it.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SERATO_PATH "/Library/Frameworks/Sl3Api.framework/Sl3Api"

enum { SL3_OK = 0, SL3_ERR_BAD_ARG = 8 };

typedef struct { uint32_t status, reserved; } sl3_usb_port_status_t;
typedef struct { uint8_t aux, left, right, unknown; } sl3_thrustate_status_data;

static void *(*sl3_open)(void);
static void (*sl3_close)(void *);
static int (*sl3_driver_timer)(void *, const uint8_t *, int, uint8_t *, int);
static int (*sl3_get_usb_port_status)(void *, sl3_usb_port_status_t *);
static int (*sl3_get_audio_controls)(void *, int, uint8_t *, int);
static int (*sl3_set_audio_controls)(void *, int, const uint8_t *, int);
static int (*sl3_set_thrustate_callback)(void *, void (*)(sl3_thrustate_status_data *));
static int (*sl3_get_firmware_version)(void *, uint32_t v[4]);   /* not one of Serato's seven */

// Serato's decks and the control byte that holds each one's output source (1 = USB, 0 = thru).
static const struct { const char *name; int offset; } kDecks[3] = { { "left", 14 }, { "right", 20 }, { "aux", 8 } };

// The thru reports the callback delivered.
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static sl3_thrustate_status_data g_last_thru;
static int g_thru_reports;

static int g_failed;
static void check(int ok, const char *what) {
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    fflush(stdout);
    if (!ok) g_failed = 1;
}

static void on_thru(sl3_thrustate_status_data *t) {
    pthread_mutex_lock(&g_mtx);
    g_last_thru = *t;
    g_thru_reports++;
    pthread_mutex_unlock(&g_mtx);
}

// A deck's output source byte, as Serato reads it (one byte at its offset), or -1.
static int read_source(void *h, int offset) {
    uint8_t b = 0xEE;
    return sl3_get_audio_controls(h, offset, &b, 1) == SL3_OK ? b : -1;
}

// Switch a deck to thru and to USB as Serato does (one byte, = !thru), check the box's control
// block follows, and leave the deck as it was.
static void check_thru(void *h, int deck) {
    char what[160];
    int off = kDecks[deck].offset;
    int before = read_source(h, off);
    snprintf(what, sizeof what, "%s deck: output source byte [%d] reads %d", kDecks[deck].name, off, before);
    check(before == 0 || before == 1, what);
    if (before < 0) return;
    // Thru (0), then USB (1): each accepted, each read back.
    uint8_t thru = 0, usb = 1;
    int e_thru = sl3_set_audio_controls(h, off, &thru, 1);
    int after_thru = read_source(h, off);
    int e_usb = sl3_set_audio_controls(h, off, &usb, 1);
    int after_usb = read_source(h, off);
    snprintf(what, sizeof what, "%s deck: sl3_set_audio_controls thru / USB accepted (%d, %d)", kDecks[deck].name, e_thru, e_usb);
    check(e_thru == SL3_OK && e_usb == SL3_OK, what);
    snprintf(what, sizeof what, "%s deck: the box follows (after thru %d, after USB %d)", kDecks[deck].name, after_thru, after_usb);
    check(after_thru == 0 && after_usb == 1, what);
    // Put it back.
    uint8_t b = (uint8_t)before;
    sl3_set_audio_controls(h, off, &b, 1);
    snprintf(what, sizeof what, "%s deck: restored", kDecks[deck].name);
    check(read_source(h, off) == before, what);
}

int main(int argc, char **argv) {
    // Load the framework as Serato does, and look up the seven functions it uses.
    const char *path = argc > 1 ? argv[1] : SERATO_PATH;
#if defined(__x86_64__)
    printf("loading %s (x86_64)\n", path);
#else
    printf("loading %s (arm64)\n", path);
#endif
    void *lib = dlopen(path, RTLD_NOW);
    if (!lib) { printf("FAIL  dlopen: %s\n", dlerror()); return 1; }
    sl3_open = dlsym(lib, "sl3_open");
    sl3_close = dlsym(lib, "sl3_close");
    sl3_driver_timer = dlsym(lib, "sl3_driver_timer");
    sl3_get_usb_port_status = dlsym(lib, "sl3_get_usb_port_status");
    sl3_get_audio_controls = dlsym(lib, "sl3_get_audio_controls");
    sl3_set_audio_controls = dlsym(lib, "sl3_set_audio_controls");
    sl3_set_thrustate_callback = dlsym(lib, "sl3_set_thrustate_callback");
    sl3_get_firmware_version = dlsym(lib, "sl3_get_firmware_version");
    check(sl3_open && sl3_close && sl3_driver_timer && sl3_get_usb_port_status && sl3_get_audio_controls &&
          sl3_set_audio_controls && sl3_set_thrustate_callback, "all seven functions Serato uses are exported");
    if (g_failed) return 1;

    // Open, register the thru callback, and check the box is reported connected (Serato reads only
    // the first word, and ignores the return code).
    void *h = sl3_open();
    check(h != NULL, "sl3_open returns a handle");
    check(sl3_set_thrustate_callback(h, on_thru) == SL3_OK, "sl3_set_thrustate_callback");
    sl3_usb_port_status_t ps = { 7, 7 };
    int e = sl3_get_usb_port_status(h, &ps);
    char what[160];
    snprintf(what, sizeof what, "sl3_get_usb_port_status -> %d {%u, %u} (expect 0 {1, 0}: connected)", e, ps.status, ps.reserved);
    check(e == SL3_OK && ps.status == 1 && ps.reserved == 0, what);
    if (ps.status != 1) { printf("no box connected: stopping\n"); return 1; }

    // The genuine-hardware check: the box's 8-byte answer is a function of the 8-byte challenge.
    uint8_t c1[8] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }, c2[8] = { 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 };
    uint8_t a1[8] = {0}, a1b[8] = {0}, a2[8] = {0}, zero[8] = {0};
    int e1 = sl3_driver_timer(h, c1, 8, a1, 8), e1b = sl3_driver_timer(h, c1, 8, a1b, 8), e2 = sl3_driver_timer(h, c2, 8, a2, 8);
    snprintf(what, sizeof what, "sl3_driver_timer -> %d, %d, %d; answer %02x%02x%02x%02x%02x%02x%02x%02x", e1, e1b, e2,
             a1[0], a1[1], a1[2], a1[3], a1[4], a1[5], a1[6], a1[7]);
    check(e1 == SL3_OK && e1b == SL3_OK && e2 == SL3_OK, what);
    check(memcmp(a1, zero, 8) != 0 && memcmp(a1, c1, 8) != 0, "sl3_driver_timer: the answer is non-zero and not the challenge echoed");
    check(memcmp(a1, a1b, 8) == 0, "sl3_driver_timer: the same challenge gives the same answer");
    check(memcmp(a1, a2, 8) != 0, "sl3_driver_timer: a different challenge gives a different answer");
    check(sl3_driver_timer(h, c1, 7, a1, 8) == SL3_ERR_BAD_ARG, "sl3_driver_timer: a 7-byte challenge is refused (8)");

    // The control block's bounds, as Rane's checks them.
    uint8_t buf[22];
    check(sl3_get_audio_controls(h, 0, buf, 22) == SL3_OK, "sl3_get_audio_controls: the whole 22-byte block");
    check(sl3_get_audio_controls(h, 21, buf, 2) == SL3_ERR_BAD_ARG, "sl3_get_audio_controls: past the end is refused (8)");
    check(sl3_get_audio_controls((void *)0x7777, 0, buf, 1) == SL3_ERR_BAD_ARG, "sl3_get_audio_controls: a handle never opened is refused (8)");

    // Per-deck thru, as Serato switches it; the box confirms each change with a thru report.
    pthread_mutex_lock(&g_mtx);
    int reports_before = g_thru_reports;
    pthread_mutex_unlock(&g_mtx);
    for (int d = 0; d < 3; d++) check_thru(h, d);
    usleep(100000);   // the library polls the driver every 15 ms
    pthread_mutex_lock(&g_mtx);
    int reports = g_thru_reports - reports_before;
    pthread_mutex_unlock(&g_mtx);
    /* The box confirms a change of output source with a 0x39 report from firmware 2.50; 2.31 has no
       such report, so with it the callback stays silent (as with Rane's own library). */
    uint32_t fw[4] = { 0 };
    bool reports_expected = !sl3_get_firmware_version || sl3_get_firmware_version(h, fw) != SL3_OK ||
                            (fw[0] << 8 | fw[1]) >= (2 << 8 | 50);
    if (reports_expected) {
        snprintf(what, sizeof what, "the thru callback was called for the changes (%d reports)", reports);
        check(reports > 0, what);
    } else {
        printf("SKIP  the thru callback (firmware %u.%02u sends no thru reports; %d seen)\n", fw[0], fw[1], reports);
    }

    // Close; Serato never does, but the control panel does.
    sl3_close(h);
    check(sl3_get_audio_controls(h, 0, buf, 1) == SL3_ERR_BAD_ARG, "sl3_close: the handle is no longer accepted (8)");
    printf("%s\n", g_failed ? "FAIL" : "PASS: all checks");
    return g_failed;
}
