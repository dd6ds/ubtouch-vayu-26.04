#!/usr/bin/env python3
# Mark undefined dynamic symbols of an ELF64 (little endian) shared object as WEAK.
# A missing weak symbol does not make dlopen() fail; the code itself is not touched.
# Used for lomiri-system-settings 1.5.0 (26.04 daily): plugins/brightness/aethercast/devicemodel.h
# declares the Qt slot DeviceModel::slotAdapterPropertiesChanged() but it is never implemented,
# so moc's metacall references a symbol that does not exist -> "Helligkeit & Anzeige" /
# "Brightness & Display" cannot be opened. The slot is never connected or invoked there.
# Usage: elf-weaken-undef.py <lib.so> <mangled symbol> [<mangled symbol> ...]
import struct, sys

path, names = sys.argv[1], set(sys.argv[2:])
b = bytearray(open(path, "rb").read())
if b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1:
    sys.exit("elf-weaken-undef: %s is not an ELF64 little-endian file" % path)
e_shoff, = struct.unpack_from("<Q", b, 0x28)
e_shentsize, e_shnum = struct.unpack_from("<HH", b, 0x3A)
secs = [struct.unpack_from("<IIQQQQIIQQ", b, e_shoff + i * e_shentsize) for i in range(e_shnum)]
done = set()
for sh_name, sh_type, _, _, sh_offset, sh_size, sh_link, _, _, sh_entsize in secs:
    if sh_type != 11:                                   # SHT_DYNSYM
        continue
    stroff = secs[sh_link][4]
    for off in range(sh_offset, sh_offset + sh_size, sh_entsize or 24):
        st_name, st_info, st_other, st_shndx = struct.unpack_from("<IBBH", b, off)
        end = b.index(b"\0", stroff + st_name)
        name = b[stroff + st_name:end].decode(errors="replace")
        if name in names and st_shndx == 0:            # undefined reference
            if st_info >> 4 == 1:                       # STB_GLOBAL -> STB_WEAK
                b[off + 4] = (2 << 4) | (st_info & 0xF)
            done.add(name)
for n in sorted(names - done):
    print("elf-weaken-undef: WARNING: %s is not an undefined symbol in %s - skipped" % (n, path))
for n in sorted(done):
    print("elf-weaken-undef: %s -> weak in %s" % (n, path.split("/")[-1]))
open(path, "wb").write(b)
