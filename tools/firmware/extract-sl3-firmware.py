#!/usr/bin/env python3
"""Extract and de-obfuscate the Rane SL 3 firmware images from Rane's official macOS driver.

Source  : Rane's "RaneSL3_2.0.1f2.pkg" (the SL 3 driver Serato DJ Pro 2.5.5 bundles and offers to
          install; inside it, Library/Frameworks/Sl3Api.framework/Versions/A/Sl3Api), or that
          Sl3Api binary itself, or a folder holding either (an expanded package, a mounted disk).
Output  : sl3_final_firmware.bin       (0x3900 B: 0x40 Rane header + 0x38C0 B of EEPROM contents;
                                        what sl3flash writes)
          sl3_bootstrap_firmware.bin   (0x19CD B, 8051 code: Rane's RAM-loaded EEPROM writer, which
                                        sl3flash loads onto a box with no firmware)
          eeprom-image-sl3.bin         (the 0x38C0 B of EEPROM contents with the boot byte at 0xC2,
                                        for sl3dump --verify, or for writing the chip directly)
          sl3_xor_key_256.bin          (the 256-byte de-obfuscation key)

The two images are embedded in the x86_64 slice of Sl3Api, obfuscated with a 256-byte repeating
XOR key (the local symbol kKeyBytes): out[i] = in[i] ^ key[i % 256]. Their offsets are those of the
known build below (Rane left no symbols on them); every result is checked against the Rane header's
length and CRC-32 and against the SHA-256 of the known build, so a different build, a wrong offset
or a damaged file stops here instead of producing an image that could leave the box unbootable.

No vendor code is executed. Requires the macOS tools pkgutil, gunzip, cpio, lipo, nm, otool.

Usage:
  extract-sl3-firmware.py <RaneSL3_2.0.1f2.pkg | Sl3Api | folder> [outdir]
"""
import hashlib, os, subprocess, sys, tempfile, zlib

KEY_LEN  = 0x100
SYM_KEY  = "kKeyBytes"
RANE_HDR = 0x40
# Known builds: file offsets of the images in the x86_64 slice, their lengths (the memcpy lengths in
# Update{Final,Bootstrap}FirmwareFromEmbedded), and the SHA-256 of each image once de-obfuscated.
BUILDS = {
    "2.0.1f2": {
        "final":     (0x6d30, 0x3900, "baabe452a65a4eceaff02189ea82c6d91b60bb82a626df4ebdf996b6d9f0e335"),
        "bootstrap": (0xa630, 0x19cd, "b2bb84e4c5bb0da2726221a7bceb28e84a9806835f799369c71b562eb40b3c31"),
    },
}
# The EEPROM's first five bytes, which the box forces whenever block 0 is written (boot byte 0xC0,
# VID 1CC5, PID 0001): the image must carry the same, or a write could never read back right.
IDENTITY = bytes([0xC0, 0xC5, 0x1C, 0x01, 0x00])


def run(*cmd, **kw):
    """Run a command and return its stdout, raising if it fails."""
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def is_macho(path):
    """True if path is a Mach-O file (thin or universal)."""
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")


def find_source(p):
    """The package or the Sl3Api binary: the argument itself, or the first found under it."""
    if os.path.isfile(p):
        return p
    for root, _, files in os.walk(p):
        for f in sorted(files):
            full = os.path.join(root, f)
            if f == "Sl3Api" and not os.path.islink(full) and is_macho(full):
                return full
            if f.endswith(".pkg") and "SL3" in f.upper():
                return full
    sys.exit(f"could not find a RaneSL3 .pkg or an Sl3Api binary under {p}")


def sl3api_from_pkg(pkg, work):
    """Expand the package under `work` and return the path of the Sl3Api binary in its payload."""
    run("pkgutil", "--expand", pkg, os.path.join(work, "pkg"))
    payload = None
    for root, _, files in os.walk(os.path.join(work, "pkg")):
        if "Payload" in files and os.path.basename(root).upper().startswith("SL3"):
            payload = os.path.join(root, "Payload")
    if not payload:
        sys.exit("the package has no SL3 component payload")
    # The payload is a gzip'd cpio archive of the installed files; unpack it.
    extract = os.path.join(work, "payload")
    os.makedirs(extract)
    with open(payload, "rb") as fp:
        gz = subprocess.Popen(["gunzip", "-c"], stdin=fp, stdout=subprocess.PIPE)
        subprocess.run(["cpio", "-idm"], stdin=gz.stdout, cwd=extract, check=True, capture_output=True)
        gz.wait()
    fw = os.path.join(extract, "Library/Frameworks/Sl3Api.framework/Versions/A/Sl3Api")
    if not os.path.isfile(fw):
        sys.exit("the package's payload has no Sl3Api.framework")
    return fw


def x86_64_slice(binpath, work):
    """A thin x86_64 copy of the binary (it ships with i386 and x86_64 slices), under `work`."""
    thin = os.path.join(work, "slice")
    archs = run("lipo", "-archs", binpath).split()
    if archs == ["x86_64"]:
        return binpath
    if "x86_64" not in archs:
        sys.exit(f"{binpath} has no x86_64 slice ({' '.join(archs)})")
    run("lipo", "-thin", "x86_64", binpath, "-output", thin)
    return thin


def file_offset(binpath, vmaddr):
    """The file offset of a virtual address, from the section that contains it."""
    out = run("otool", "-l", binpath).splitlines()
    for i, line in enumerate(out):
        if line.strip().startswith("sectname "):
            addr = size = offset = None
            for t in (s.strip() for s in out[i + 1:i + 9]):
                if t.startswith("addr "):   addr = int(t.split()[1], 16)
                if t.startswith("size "):   size = int(t.split()[1], 16)
                if t.startswith("offset "): offset = int(t.split()[1])
            if addr is not None and size and offset and addr <= vmaddr < addr + size:
                return offset + (vmaddr - addr)
    sys.exit(f"no section holds address 0x{vmaddr:x}")


def key_offset(binpath):
    """The file offset of the XOR key, from its local symbol."""
    for line in run("nm", "-n", binpath).splitlines():
        parts = line.split()
        if len(parts) >= 3 and SYM_KEY in parts[-1]:
            return file_offset(binpath, int(parts[0], 16))
    sys.exit(f"no {SYM_KEY} symbol: not Rane's Sl3Api, or a build this script doesn't know")


def deobfuscate(data, key):
    """Undo the repeating-XOR obfuscation."""
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def check_final(final):
    """The Rane header: copyright, payload length, CRC-32 (big-endian) over the payload, and the
    identity the box forces into EEPROM bytes 0-4."""
    if not final.startswith(b"Copyright 20"):
        sys.exit("the final image lacks the Rane copyright header")
    paylen = int.from_bytes(final[0x38:0x3c], "big")
    if paylen + RANE_HDR != len(final):
        sys.exit(f"the final image's payload length 0x{paylen:x} + 0x40 is not its size 0x{len(final):x}")
    want = int.from_bytes(final[0x3c:0x40], "big")
    got = zlib.crc32(final[RANE_HDR:]) & 0xFFFFFFFF
    if got != want:
        sys.exit(f"the final image's CRC 0x{got:08x} doesn't match its header (0x{want:08x})")
    if final[RANE_HDR:RANE_HDR + 5] != IDENTITY:
        sys.exit("the final image doesn't start with the SL 3's EEPROM identity (C0 C5 1C 01 00)")
    return paylen, want


def main():
    # The source and the output directory.
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = find_source(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "sl3-fw-out"
    print(f"[*] source: {src}")

    # Find Sl3Api's x86_64 slice and carve the key and images out of it, in a temporary folder that
    # is discarded on exit, so no copy of the vendor binary is left behind.
    with tempfile.TemporaryDirectory(prefix="sl3fw.") as work:
        binpath = sl3api_from_pkg(src, work) if src.endswith(".pkg") else src
        thin = x86_64_slice(binpath, work)
        with open(thin, "rb") as f:
            blob = f.read()
        koff = key_offset(thin)
        key = blob[koff:koff + KEY_LEN]
        # Try each known build: the one whose images de-obfuscate to the known contents.
        found = None
        for build, imgs in BUILDS.items():
            got = {}
            for name, (off, length, sha) in imgs.items():
                img = deobfuscate(blob[off:off + length], key)
                if hashlib.sha256(img).hexdigest() != sha:
                    break
                got[name] = img
            else:
                found = (build, got)
                break
    if not found:
        sys.exit("the images don't match a known Sl3Api build (known: " + ", ".join(BUILDS) + ")")
    build, imgs = found
    final, boot = imgs["final"], imgs["bootstrap"]
    paylen, crc = check_final(final)
    if boot[0] != 0x02:
        sys.exit("the bootstrap doesn't start with an 8051 LJMP")

    # The image for the EEPROM itself: the payload with the boot byte at 0xC2 (boot the firmware).
    eeprom = bytearray(final[RANE_HDR:])
    eeprom[0] = 0xC2

    # Write the outputs (firmware images; *.bin is git-ignored in this folder).
    os.makedirs(out, exist_ok=True)
    for name, data in (("sl3_final_firmware.bin", final), ("sl3_bootstrap_firmware.bin", boot),
                       ("eeprom-image-sl3.bin", bytes(eeprom)), ("sl3_xor_key_256.bin", key)):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        print(f"[+] wrote {os.path.join(out, name)} ({len(data)} B)")
    print(f"[*] Sl3Api {build}: firmware {final[0x27]}.{final[0x28]:02d}, payload 0x{paylen:x} B, "
          f"CRC 0x{crc:08x}; bootstrap {len(boot)} B")


if __name__ == "__main__":
    main()
