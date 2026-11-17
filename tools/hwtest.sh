#!/bin/bash
# hwtest.sh [--loopback] [--no-physical] — the SL 3 hardware tests in one run, with a PASS / FAIL /
# SKIP summary. Run by `make hwtest` (ARGS="--loopback ..."), which builds what it needs first.
#
# The tests run in the order that needs the fewest physical steps:
#   1. with the box attached, nothing else: driver status, Sl3Api as Serato calls it (both slices),
#      sample-rate switching, the phono sensitivity, the input safety offset setting, and the early
#      capture read working;
#   2. with --loopback (a cable from Left Deck Out L to Left Deck In L, channel 3; the tests play
#      clicks and a loud tone into that output, so pass it only when the cable is in): restarts, a
#      glitch test (with no 0x37 heartbeat sent), the other sample rate, IO buffer sizes, the output
#      volume and mute, the level meters, and in a debug build (installed with make install DEBUG=1)
#      the glitch test under load, the early capture read and the fault hooks;
#   3. unless --no-physical: steps for a person at the box (flip each deck's LINE/PHONO switch,
#      unplug and replug while idle and while a stream runs). The script prints what to do and waits
#      until it sees the change, so nothing needs typing.
#
# Exit status 0 = nothing failed. The full output goes to a log file, named at the end.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B="$ROOT/tools/latency/bin"
PANEL="$ROOT/sl3panel"
APITEST="$ROOT/sl3apitest"
DEV="SL 3"
SUBSYS=com.rane.sl3
LOOP=3                              # the looped-back channel: Left Deck L
OTHER=4                             # a channel next to it, which nothing plays to
WAIT_S=${HWTEST_WAIT:-120}          # how long to wait for a physical step

LOOPBACK=0; PHYSICAL=1
for a in "$@"; do
    case "$a" in
        --loopback) LOOPBACK=1 ;;
        --no-physical) PHYSICAL=0 ;;
        *) echo "usage: hwtest.sh [--loopback] [--no-physical]"; exit 2 ;;
    esac
done

LOG="${TMPDIR:-/tmp}"; LOG="${LOG%/}/sl3-hwtest-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------------------- helpers

RESULTS=()
record() {   # <PASS|FAIL|SKIP> <test> [detail]
    RESULTS+=("$1|$2|${3:-}")
    printf '%-4s  %s%s\n' "$1" "$2" "${3:+  ($3)}"
}

status() { "$PANEL" status 2>&1; }
connected() { status | grep -q 'USB Connected : YES'; }
field() {    # the value of an sl3panel status line, e.g. field 'Sample Rate'
    status | sed -nE "s/^  $1 *: *//p" | head -1
}

wait_until() {   # <description> <command...>: poll every half second, up to WAIT_S
    local what=$1; shift
    local t=0
    while ! "$@" >/dev/null 2>&1; do
        sleep 0.5; t=$((t + 1))
        if [ $t -ge $((WAIT_S * 2)) ]; then echo "      timed out after ${WAIT_S} s waiting for: $what"; return 1; fi
    done
}
not() { ! "$@"; }

driver_log_since() {   # <start time> <grep pattern>: the driver's log lines since then
    sleep 1
    /usr/bin/log show --start "$1" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
        | grep -E "$2" | sed -E 's/.*\] \[SL3\] //'
}
now() { date '+%Y-%m-%d %H:%M:%S'; }

# The user's output volume (the main volume and each channel's) and mute, saved before a test
# changes them and put back afterwards (by a trap if the script is interrupted). save_volume fails if
# the driver has no volume controls.
save_volume() {
    local v
    v=$("$B/volctl" "$DEV") || return 1
    SAVED_DB=$(echo "$v" | sed -nE 's/^volume (-?[0-9.e+-]+) dB.*/\1/p')
    SAVED_CH=$(echo "$v" | sed -nE 's/.*, channels (.*) dB, mute [01]$/\1/p')
    SAVED_MUTE=$(echo "$v" | sed -nE 's/.*mute ([01])$/\1/p')
    [ -n "$SAVED_DB" ] && [ -n "$SAVED_MUTE" ] || return 1
    trap 'EXITING=1; restore_volume' EXIT
    trap 'exit 130' INT TERM
}
neutral_volume() {   # the main volume and every channel at 0 dB, unmuted; fails if any setting does
    local ch ok=0
    "$B/volctl" "$DEV" unmute >/dev/null || ok=1
    "$B/volctl" "$DEV" 0 >/dev/null || ok=1
    for ch in 1 2 3 4 5 6; do "$B/volctl" "$DEV" 0 $ch >/dev/null || ok=1; done
    return $ok
}
restore_volume() {
    trap - EXIT INT TERM
    [ -n "${SAVED_DB:-}" ] || return 0   # nothing was saved
    local m=unmute ch=0 db ok=1
    [ "$SAVED_MUTE" = 1 ] && m=mute
    "$B/volctl" "$DEV" "$SAVED_DB" >/dev/null || ok=0
    for db in $SAVED_CH; do
        ch=$((ch + 1))
        "$B/volctl" "$DEV" "$db" $ch >/dev/null || ok=0
    done
    "$B/volctl" "$DEV" $m >/dev/null || ok=0
    if [ $ok = 1 ]; then SAVED_DB=; return 0; fi
    # Failed (the box may be unplugged): try once more when the script ends, then give up.
    if [ -z "${RESTORE_RETRY:-}" ] && [ -z "${EXITING:-}" ]; then
        RESTORE_RETRY=1
        trap 'EXITING=1; restore_volume' EXIT
        echo "      could not put the output volume back yet: will try again when the tests end"
    else
        echo "      could not put the output volume back ($SAVED_DB dB, channels $SAVED_CH dB, mute $SAVED_MUTE): set it by hand"
        SAVED_DB=
    fi
    return 1
}

all_thru() { [ "$(status | grep -c 'Mode: ANALOG THRU')" = 3 ]; }
deck_input_is() { field "$1" | grep -q "^$2"; }   # <Aux|Left Deck|Right Deck> <LINE|PHONO>
input_is() { deck_input_is 'Left Deck' "$1"; }    # the looped-back deck

# ---------------------------------------------------------------------------- 0. preconditions

echo "SL 3 hardware tests, $(date)"
for tool in "$PANEL" "$APITEST" "$B/rtlat" "$B/sinetest" "$B/setrate" "$B/sl3dbg" "$B/chrec" "$B/volctl" "$B/meters"; do
    [ -x "$tool" ] || { echo "missing $tool: run make hwtest (it builds the tools)"; exit 2; }
done
if ! connected; then
    echo "No SL 3 connected (or the driver isn't loaded): connect the box and run again."
    "$PANEL" status
    exit 2
fi
# A debug build accepts the driver's debug commands; errpkts 0 changes nothing.
if "$B/sl3dbg" errpkts 0 >/dev/null 2>&1; then BUILD=debug; else BUILD=release; fi
echo "driver: $BUILD build; firmware $(field 'Firmware Ver')"
[ $BUILD = release ] && echo "(the debug-only tests will be skipped: make install DEBUG=1 installs a debug build)"
echo

# ---------------------------------------------------------------------------- 1. the box only

echo "== 1. box attached, nothing else"

# The status: connected, the running firmware's version (not the firmware loader's 2.25), a high-speed
# link, and every deck's switch and output source reported.
fw=$(field 'Firmware Ver'); link=$(field 'USB Link')
decks=$(status | grep -cE '^  (Aux|Left Deck|Right Deck) *: (LINE|PHONO) ')
if [ -n "$fw" ] && [ "$fw" != "0.00" ] && [ "$fw" != "2.25" ] && [ "$link" = "high speed" ] && [ "$decks" = 3 ]; then
    record PASS "status" "firmware $fw, $link"
else
    record FAIL "status" "firmware '$fw', link '$link', $decks decks reported"
fi

# Sl3Api the way Serato DJ Pro 2.5.5 calls it: natively, and the x86_64 slice Serato loads.
if "$APITEST" > /dev/null 2>&1; then record PASS "Sl3Api, arm64"; else record FAIL "Sl3Api, arm64" "run ./sl3apitest"; fi
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    if arch -x86_64 "$APITEST" > /dev/null 2>&1; then record PASS "Sl3Api, x86_64 (Rosetta)"
    else record FAIL "Sl3Api, x86_64 (Rosetta)" "run arch -x86_64 ./sl3apitest"; fi
else
    record SKIP "Sl3Api, x86_64 (Rosetta)" "Rosetta not installed"
fi

# Sample-rate switching: to the other rate and back, the driver's status following each time.
orig=$("$B/setrate" "$DEV" | grep -oE '[0-9]{5}' | head -1); orig=${orig:-48000}
other=$([ "$orig" = 48000 ] && echo 44100 || echo 48000)
ok=1
for r in $other $orig; do
    "$B/setrate" "$DEV" "$r" >/dev/null
    wait_until "the driver to report $r Hz" sh -c "'$PANEL' status | grep -q 'Sample Rate   : $r Hz'" || ok=0
done
[ $ok = 1 ] && record PASS "sample rate $orig -> $other -> $orig" || record FAIL "sample rate $orig -> $other -> $orig"

# The phono sensitivity: set the Left deck's one step away and back, the box reporting each (the box
# keeps it in its EEPROM, so it is put back as it was).
sens() { field 'Left Deck' | grep -oE 'Phono sens: [0-9.]+' | grep -oE '[0-9.]+$'; }
s0=$(sens)
if [ -z "$s0" ]; then
    record FAIL "phono sensitivity" "not reported"
else
    s1=$(awk -v s="$s0" 'BEGIN { printf "%.1f", (s < 10 ? s + 0.5 : s - 0.5) }')
    "$PANEL" sens left "$s1" >/dev/null; got=$(sens)
    "$PANEL" sens left "$s0" >/dev/null; back=$(sens)
    [ "$got" = "$s1" ] && [ "$back" = "$s0" ] && record PASS "phono sensitivity" "$s0 -> $s1 -> $s0 mV"         || record FAIL "phono sensitivity" "$s0 -> '$got' -> '$back' mV"
fi

# The input safety offset setting: set 2 ms with nothing streaming, and the driver must set the device
# up again with it (the status reports what CoreAudio is using); then put the setting back.
# sl3panel prints the setting exactly (to the microsecond), so it is put back exactly.
orig_ms=$("$PANEL" safety | grep -oE '[0-9]+(\.[0-9]+)? ms' | head -1 | cut -d' ' -f1)
if [ -z "$orig_ms" ]; then
    record FAIL "input safety offset setting" "sl3panel safety: no setting"
else
    ok=1
    "$PANEL" safety 2 >/dev/null || ok=0
    WAIT_S=5 wait_until "the driver to use 2 ms" sh -c "'$PANEL' status | grep -q 'Input Safety  : 2 ms'" || ok=0
    "$PANEL" safety "$orig_ms" >/dev/null || ok=0
    WAIT_S=5 wait_until "the driver to use $orig_ms ms again" sh -c "'$PANEL' status | grep -q 'Input Safety  : $orig_ms ms'" || ok=0
    [ $ok = 1 ] && record PASS "input safety offset setting" "2 ms, then back to $orig_ms ms" \
                || record FAIL "input safety offset setting" "status: $(field 'Input Safety')"
fi

# The early capture read: after a few seconds of capture (any input, no cable needed), the driver
# must judge it working, and no input must have dropped out during it (the dropout count runs from
# when the box connected, so compare before and after).
drops0=$(field 'Input Dropouts')
"$B/chrec" "$DEV" 3 "${TMPDIR:-/tmp}/sl3-hwtest-chrec.wav" >/dev/null 2>&1
er=$(field 'Early Read'); drops1=$(field 'Input Dropouts')
drops=$(( ${drops1:-0} - ${drops0:-0} ))
if [ "$er" = "working" ] && [ -n "$drops1" ] && [ "$drops" = 0 ]; then
    record PASS "early capture read working" "USB hubs: $(field 'USB Hubs')"
else
    record FAIL "early capture read working" "early read '$er', input dropouts '$drops'"
fi
echo

# ---------------------------------------------------------------------------- 2. loopback

echo "== 2. loopback cable"
if [ $LOOPBACK = 0 ]; then
    for t in "restarts" "glitch test, 30 s, no heartbeat" "glitch test idle + loaded (dptest)" "the other sample rate" "IO buffer sizes" "output volume and mute" "level meters" "capture packet sizes" "early capture read" "early read reported not working" "fault hook: USB stall" "fault hook: errored capture packets"; do
        record SKIP "$t" "no --loopback"
    done
else
    # The line-level loopback signal clips the phono preamp: wait for the switch to be on LINE.
    if ! input_is LINE; then
        echo "   >>> Set the Left deck's LINE/PHONO switch on the box to LINE."
        wait_until "the switch on LINE" input_is LINE
    fi

    # Every test here plays at full level: the user's output volume and mute are saved, set to 0 dB
    # and unmuted for the section, and put back at its end (by a trap if the script is interrupted).
    if save_volume; then have_volume=1; else have_volume=0; fi
    if [ $have_volume = 0 ] || ! neutral_volume; then
        echo "   (could not set the output to 0 dB, unmuted: the loopback tests may fail for that reason)"
    fi

    # Three streams in a row, each starting cleanly and finding all its clicks.
    if "$ROOT/tools/latency/restartcheck.sh" > /dev/null 2>&1; then record PASS "restarts"
    else record FAIL "restarts" "run tools/latency/restartcheck.sh"; fi

    # A 30 s glitch test with the Mac idle. The driver sends the box no 0x37 heartbeat (Rane's driver
    # didn't either): the deck must play USB audio throughout, at full level, without one.
    out=$("$B/sinetest" "$DEV" $LOOP $LOOP 30 128 | grep RESULT)
    echo "$out" | grep -q 'RESULT: 0 glitches, 0 level drops' && record PASS "glitch test, 30 s, no heartbeat" \
        || record FAIL "glitch test, 30 s, no heartbeat" "$out"

    # Idle and with every core loaded, with the driver's counters: a debug build only.
    if [ $BUILD = debug ]; then
        if "$ROOT/tools/latency/dptest.sh" 30 > /dev/null 2>&1; then record PASS "glitch test idle + loaded (dptest)"
        else record FAIL "glitch test idle + loaded (dptest)" "run tools/latency/dptest.sh 30"; fi
    else
        record SKIP "glitch test idle + loaded (dptest)" "release build (make install DEBUG=1)"
    fi

    # The other sample rate: every click found, and a clean 10 s glitch test.
    "$B/setrate" "$DEV" $other >/dev/null; sleep 1
    lat=$("$B/rtlat" "$DEV" $LOOP $LOOP 4 128 | grep -E 'mean|not found' | head -1)
    sine=$("$B/sinetest" "$DEV" $LOOP $LOOP 10 128 | grep RESULT)
    "$B/setrate" "$DEV" "$orig" >/dev/null
    if echo "$lat" | grep -q '(4/4 clicks)' && echo "$sine" | grep -q 'RESULT: 0 glitches, 0 level drops'; then
        record PASS "the other sample rate" "$other Hz: $(echo "$lat" | grep -oE 'DVS round trip est\. [0-9.]+ ms')"
    else
        record FAIL "the other sample rate" "$other Hz: $lat / $sine"
    fi

    # IO buffer sizes, at both rates: every click found at each, and the round trip measured (48 is
    # Serato's IO buffer alignment for the SL 3; 45 is 1 ms at 44.1 kHz). Records what each size gives.
    ok=1; detail=""
    for r in 44100 48000; do
        "$B/setrate" "$DEV" $r >/dev/null; sleep 1
        for buf in 32 45 48 64 128 256 512; do
            lat=$("$B/rtlat" "$DEV" $LOOP $LOOP 4 $buf | grep -E 'mean|not found' | head -1)
            rt=$(echo "$lat" | grep -oE 'DVS round trip est\. [0-9.]+' | grep -oE '[0-9.]+$')
            echo "$lat" | grep -q '(4/4 clicks)' || { ok=0; rt="FAIL"; }
            detail="$detail $((r / 1000))k/$buf:${rt:-?}"
        done
    done
    "$B/setrate" "$DEV" "$orig" >/dev/null
    [ $ok = 1 ] && record PASS "IO buffer sizes" "round trip ms:$detail" || record FAIL "IO buffer sizes" "round trip ms:$detail"

    # Output volume. With everything at 0 dB every click is found at full level; the looped-back channel
    # at -20 dB brings them down 20 dB; the channel next to it at -20 dB leaves it alone; the virtual main volume (the
    # volume keys) at the slider position for -20 dB (0.6875 squared, by CoreAudio's standard volume
    # curve) sets the main volume to -20 dB, leaving the channels' own levels, and brings the clicks
    # down 20 dB; mute silences them. (rtlat reads quieter clicks a
    # frame or two later: it finds a click at a fixed threshold, which the converters' pre-ringing
    # crosses sooner on a loud click. So only levels are checked here; the restart test above covers
    # the round trip.)
    if [ $have_volume = 1 ]; then
        peak() { grep -oE 'peak [0-9.]+' | tail -1 | grep -oE '[0-9.]+$'; }
        db() { awk -v r="$1" -v a="$2" 'BEGIN { if (r > 0 && a > 0) printf "%.1f", 20 * log(a / r) / log(10); else print "none" }'; }
        full=$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128); ref=$(echo "$full" | peak)
        "$B/volctl" "$DEV" -20 $LOOP >/dev/null
        ch1=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 $LOOP >/dev/null; "$B/volctl" "$DEV" -20 $OTHER >/dev/null
        ch2=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 $OTHER >/dev/null
        keys=$("$B/volctl" "$DEV" main 0.47265625)
        main=$(db "$ref" "$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | peak)")
        "$B/volctl" "$DEV" 0 >/dev/null; "$B/volctl" "$DEV" mute >/dev/null
        muted=$("$B/rtlat" "$DEV" $LOOP $LOOP 3 128 | grep -c 'not found')
        neutral_volume
        detail="channel $LOOP at -20 dB: $ch1 dB; channel $OTHER at -20 dB: channel $LOOP $ch2 dB; volume keys: $main dB ($keys); muted: $muted/3 clicks gone"
        if echo "$full" | grep -q '(3/3 clicks)' && [ "$muted" = 3 ] &&
           awk -v a="$ch1" -v b="$ch2" -v c="$main" 'BEGIN { exit !(a > -21 && a < -19 && b > -0.5 && b < 0.5 && c > -21 && c < -19) }' &&
           echo "$keys" | grep -qE '^volume -20(\.[0-9]*)? dB, channels 0 0 0 0 0 0 dB'; then
            record PASS "output volume and mute" "$detail"
        else
            record FAIL "output volume and mute" "$detail"
        fi
    else
        record FAIL "output volume and mute" "the driver has no output volume controls (volctl)"
    fi

    # The level meters ('sl3m', which the control panel shows): while sinetest plays its 0.4 tone
    # (-8 dB) on the looped-back output, that output must read -8 dB +-1, its input must clearly get it
    # (the loopback), and the other outputs, which nothing plays to, must be silent.
    "$B/sinetest" "$DEV" $LOOP $LOOP 4 128 >/dev/null 2>&1 &
    sine=$!
    sleep 1.5
    m=$("$B/meters" "$DEV" 1.5)
    wait $sine
    if awk -v m="$m" -v lp=$LOOP 'BEGIN {
            gsub(/in |, out | dB/, " ", m); n = split(m, v, " ")
            if (n != 12) exit 1
            for (i = 7; i <= 12; i++) if (i != 6 + lp && v[i] != "-inf" && v[i] + 0 > -60) exit 1
            exit !(v[6 + lp] + 0 > -9 && v[6 + lp] + 0 < -7 && v[lp] != "-inf" && v[lp] + 0 > -20) }'; then
        record PASS "level meters" "$m"
    else
        record FAIL "level meters" "${m:-no reading}"
    fi

    # The box's capture packet sizes (debug build), at each rate: how many frames each microframe's
    # packet carries. The playback packet sizes are steered to match them (implicit feedback), so they
    # must be the ones expected: 5 and 6 at 44.1 kHz (5.5125 on average); 6 at 48 kHz, with the odd 5
    # or 7 where the box corrects its clock (seen on an SL 3: about 0.5%), so up to 1% of those.
    if [ $BUILD = debug ]; then
        ok=1; detail=""
        for r in 44100 48000; do
            "$B/setrate" "$DEV" $r >/dev/null; sleep 1
            start=$(now)
            "$B/sinetest" "$DEV" $LOOP $LOOP 3 128 >/dev/null 2>&1
            h=$(driver_log_since "$start" 'DBG capture packet sizes' | head -1 | sed -E 's/.*\): *//')
            detail="$detail $((r / 1000))k:${h:-none};"
            if [ $r = 44100 ]; then
                echo "$h" | grep -qE '^5:[0-9]+ 6:[0-9]+$' || ok=0
            else
                awk -v h="$h" 'BEGIN { n = split(h, kv, " "); six = 0; other = 0
                    for (i = 1; i <= n; i++) { split(kv[i], p, ":")
                        if (p[1] == 6) six += p[2]; else if (p[1] == 5 || p[1] == 7) other += p[2]; else exit 1 }
                    exit !(six > 0 && other <= (six + other) / 100) }' || ok=0
            fi
        done
        "$B/setrate" "$DEV" "$orig" >/dev/null
        [ $ok = 1 ] && record PASS "capture packet sizes" "$detail" || record FAIL "capture packet sizes" "$detail"
    fi

    # The early capture read (debug build): a 20 ms stall in USB completion delivery, 3 s into a 10 s
    # glitch test at a 64-frame buffer, must make no gap (ReadInput takes the packets from the queued
    # buffers, not from the late completions), and the driver's early-read counters must show no frame
    # placed differently from the completion and none missing when ReadInput asked for it.
    if [ $BUILD = debug ]; then
        start=$(now)
        ( sleep 3; "$B/sl3dbg" stall 20 >/dev/null ) &
        sine=$("$B/sinetest" "$DEV" $LOOP $LOOP 10 64 | grep RESULT); wait
        er=$(driver_log_since "$start" 'DBG early read result' | head -1)
        gap=$(driver_log_since "$start" 'Capture: [0-9]+ ms not captured' | head -1)
        diff=$(echo "$er" | grep -oE 'completion found [0-9]+ different' | grep -oE '[0-9]+')
        short=$(echo "$er" | grep -oE 'SILENCE \(not captured yet\) [0-9]+' | grep -oE '[0-9]+$')
        margin=$(echo "$er" | grep -oE 'least margin -?[0-9.]+ ms')
        if echo "$sine" | grep -q ' 0 glitches' && [ -z "$gap" ] && [ "${diff:-x}" = 0 ] && [ "${short:-x}" = 0 ]; then
            record PASS "early capture read" "20 ms stall, no gap; $margin"
        else
            record FAIL "early capture read" "result '$sine', different ${diff:-?}, missing ${short:-?}, ${gap:-no gap logged}"
        fi
    fi

    # The early read reported not working (debug build): with the early reader switched off (as on a
    # Mac where it can't work), a stream must judge it not working, and leave the input safety offset
    # alone; setting the setting again has the next stream judge it afresh.
    if [ $BUILD = debug ]; then
        set_ms=$("$PANEL" safety | grep -oE '[0-9]+(\.[0-9]+)? ms' | head -1 | cut -d' ' -f1)
        "$B/sl3dbg" noearly 1 >/dev/null
        "$B/sinetest" "$DEV" $LOOP $LOOP 3 64 >/dev/null 2>&1
        "$B/sl3dbg" noearly 0 >/dev/null
        er=$(field 'Early Read'); safety=$(field 'Input Safety')
        "$PANEL" safety "$set_ms" >/dev/null
        WAIT_S=5 wait_until "the judgement cleared" sh -c "'$PANEL' status | grep -q 'Early Read    : not judged yet'"; cleared=$?
        if [ "${er#NOT WORKING}" != "$er" ] && [ "$safety" = "$("$PANEL" status | sed -nE 's/^  Input Safety *: *//p')" ] && [ $cleared = 0 ]; then
            record PASS "early read reported not working" "offset left at $safety; judged afresh after setting it"
        else
            record FAIL "early read reported not working" "early read '$er', offset '$safety', cleared $([ $cleared = 0 ] && echo yes || echo no)"
        fi
    fi

    # The fault hooks (debug build), each injected 3 s into a 10 s glitch test: a 100 ms stall in USB
    # completion delivery (the driver must fill the gap with silence and log it) and 20 errored
    # capture packets (the driver must take them, and playback must stay matched to capture: sent -
    # captured within +-2 frames at the end). Either way the stream runs to the end, never restarted.
    if [ $BUILD = debug ]; then
        for hook in "stall 100" "errpkts 20"; do
            start=$(now)
            ( sleep 3; "$B/sl3dbg" $hook >/dev/null ) &
            sine=$("$B/sinetest" "$DEV" $LOOP $LOOP 10 128 | grep RESULT); wait
            starts=$(driver_log_since "$start" 'Streaming started' | wc -l | tr -d ' ')
            if [ "$hook" = "stall 100" ]; then
                name="fault hook: USB stall"
                seen=$(driver_log_since "$start" 'Capture: [0-9]+ ms not captured' | head -1)
                balanced=1
            else
                name="fault hook: errored capture packets"
                seen=$(driver_log_since "$start" 'capture packets treated as errored' | head -1)
                sc=$(driver_log_since "$start" 'dp result' | grep -oE 'sent-captured now -?[0-9.]+' | head -1 | grep -oE '[-0-9.]+$')
                balanced=$(awk -v v="${sc:-99}" 'BEGIN { print (v >= -2 && v <= 2) ? 1 : 0 }')
                seen="$seen; sent-captured ${sc:-?}"
            fi
            if [ -n "$sine" ] && [ -n "${seen%%;*}" ] && [ "$balanced" = 1 ] && [ "$starts" -le 1 ]; then
                record PASS "$name" "$seen"
            else
                record FAIL "$name" "result '$sine', log '$seen', $starts stream starts"
            fi
        done
    else
        record SKIP "capture packet sizes" "release build (make install DEBUG=1)"
        record SKIP "early capture read" "release build (make install DEBUG=1)"
        record SKIP "early read reported not working" "release build (make install DEBUG=1)"
        record SKIP "fault hook: USB stall" "release build (make install DEBUG=1)"
        record SKIP "fault hook: errored capture packets" "release build (make install DEBUG=1)"
    fi
    [ $have_volume = 1 ] && restore_volume
fi
echo

# ---------------------------------------------------------------------------- 3. physical steps

echo "== 3. steps at the box"
if [ $PHYSICAL = 0 ]; then
    for t in "LINE/PHONO switches reported" "unplug and replug, idle" "volume and mute survive a replug" "unplug and replug, mid-stream"; do
        record SKIP "$t" "--no-physical"
    done
else
    # The LINE/PHONO switches, one per deck: the status must follow each both ways, and only that
    # deck's once the switch has settled (the firmware reads the switches without debouncing, and on an
    # SL 3 flipping one switch made its neighbour read PHONO for about 0.2 s). Each ends where it started.
    ok=1; detail=""
    for deck in "Aux" "Left Deck" "Right Deck"; do
        first=$(deck_input_is "$deck" PHONO && echo LINE || echo PHONO)
        second=$([ $first = PHONO ] && echo LINE || echo PHONO)
        before=$(status | grep -E '^  (Aux|Left Deck|Right Deck) *:' | grep -v "^  $deck *:" | cut -c1-24)
        echo "   >>> Flip the $deck's LINE/PHONO switch to $first."
        if wait_until "the $deck on $first" deck_input_is "$deck" $first; then
            sleep 1   # the box doesn't debounce: a neighbouring deck can read PHONO for ~0.2 s mid-flip
            others=$(status | grep -E '^  (Aux|Left Deck|Right Deck) *:' | grep -v "^  $deck *:" | cut -c1-24)
            [ "$others" = "$before" ] || { ok=0; detail="$detail $deck moved another deck's;"; }
            echo "   >>> Flip it back to $second."
            wait_until "the $deck on $second" deck_input_is "$deck" $second || { ok=0; detail="$detail $deck not seen back on $second;"; }
        else
            ok=0; detail="$detail $deck not seen on $first;"
        fi
    done
    [ $ok = 1 ] && record PASS "LINE/PHONO switches reported" "each deck's own" || record FAIL "LINE/PHONO switches reported" "$detail"

    # Unplug and replug with nothing playing: the device goes, comes back, and puts every deck on
    # analogue thru. The output volume, set to -20 dB (channels at 0 dB) and muted first, comes back
    # the same. (That shows the settings survive a replug; it can't show who kept them, since the
    # driver's own copy outlives the unplug too. The HAL restores a device's controls whenever it is
    # published.) The user's own setting is put back afterwards.
    if save_volume; then
        have_volume=1
        neutral_volume; "$B/volctl" "$DEV" -20 >/dev/null; "$B/volctl" "$DEV" mute >/dev/null
    else
        have_volume=0
    fi
    echo "   >>> Unplug the SL 3's USB cable."
    if wait_until "the box to go" not connected; then
        echo "   >>> Plug it back in."
        if wait_until "the box to return" connected && wait_until "every deck on thru" all_thru; then
            record PASS "unplug and replug, idle"
            if [ $have_volume = 1 ]; then
                vol=$("$B/volctl" "$DEV")
                [ "$vol" = "volume -20 dB, channels 0 0 0 0 0 0 dB, mute 1" ] && record PASS "volume and mute survive a replug" \
                    || record FAIL "volume and mute survive a replug" "$vol"
            else
                record SKIP "volume and mute survive a replug" "the driver has no output volume controls"
            fi
        else
            record FAIL "unplug and replug, idle"
            record SKIP "volume and mute survive a replug" "the box did not come back"
        fi
    else
        record FAIL "unplug and replug, idle" "unplug not seen"
        record SKIP "volume and mute survive a replug" "unplug not seen"
    fi
    [ $have_volume = 1 ] && restore_volume

    # Unplug while a stream runs (a silent, input-only one) and replug: coreaudiod survives, the
    # driver ends the stream cleanly, and a new stream starts after the replug.
    caud=$(pgrep -x coreaudiod)
    start=$(now)
    "$B/chrec" "$DEV" 60 "${TMPDIR:-/tmp}/sl3-hwtest-chrec.wav" >/dev/null 2>&1 &
    rec=$!
    sleep 2
    echo "   >>> A stream is running: unplug the SL 3's USB cable."
    if wait_until "the box to go" not connected; then
        kill $rec 2>/dev/null; wait $rec 2>/dev/null
        echo "   >>> Plug it back in."
        wait_until "the box to return" connected && wait_until "every deck on thru" all_thru
        back=$?
        # A new stream after the replug.
        "$B/chrec" "$DEV" 2 "${TMPDIR:-/tmp}/sl3-hwtest-chrec.wav" >/dev/null 2>&1
        ended=$(driver_log_since "$start" 'Streaming stopped \(box disconnected\)' | head -1)
        started=$(driver_log_since "$start" 'Streaming started' | wc -l | tr -d ' ')
        if [ $back = 0 ] && [ "$(pgrep -x coreaudiod)" = "$caud" ] && [ -n "$ended" ] && [ "$started" -ge 2 ]; then
            record PASS "unplug and replug, mid-stream"
        else
            record FAIL "unplug and replug, mid-stream" "returned $([ $back = 0 ] && echo yes || echo no), coreaudiod pid $caud -> $(pgrep -x coreaudiod), stream end logged: ${ended:-no}, streams started $started"
        fi
    else
        kill $rec 2>/dev/null; wait $rec 2>/dev/null
        record FAIL "unplug and replug, mid-stream" "unplug not seen"
    fi
fi
echo

# ---------------------------------------------------------------------------- summary

pass=0; fail=0; skip=0
echo "== summary ($BUILD build)"
for r in "${RESULTS[@]}"; do
    IFS='|' read -r s name detail <<< "$r"
    printf '%-4s  %s\n' "$s" "$name"
    case $s in PASS) pass=$((pass + 1)) ;; FAIL) fail=$((fail + 1)) ;; SKIP) skip=$((skip + 1)) ;; esac
done
echo "$pass passed, $fail failed, $skip skipped. Log: $LOG"
[ $fail = 0 ] && echo "PASS" || echo "FAIL"
exit $([ $fail = 0 ] && echo 0 || echo 1)
