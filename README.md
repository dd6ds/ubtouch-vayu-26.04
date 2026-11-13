# Ubuntu Touch 26.04 (early) for Xiaomi Poco X3 Pro (vayu)

*Deutsch: [weiter unten](#deutsch)*

Build script and GitHub Actions workflow that produce a flash kit with **Ubuntu Touch 26.04** (UBports
`26.04-1.x` daily test channel) for the Poco X3 Pro (**vayu**). vayu is not part of that channel – the kit combines
its generic rootfs with the vayu community port (Halium 11) and patches what 26.04 breaks on vayu.

> ⚠️ Unofficial, early test build. Flashing wipes **all data**. For daily use the
> [24.04 kit](https://github.com/dd6ds/ubtouch_xiaomi_poc_-x3_pro) is the safer choice.

**Status (2026-11-13, build 471):** boots to the UI, setup wizard, touch, scaling, Settings, Phone, Browser,
OpenStore and Bluetooth scanning work. The rest of the hardware is not re-tested on 26.04 yet.

## What 26.04 needs on vayu

| Problem | Fix applied by `build-2604.sh` |
|---|---|
| Hangs at the boot splash (Lomiri crash loop, no adb) | qtmir: match Mir display buffers to the screen by position |
| Small cut-out picture, misplaced touch | qtmir: keep the Mir output scale at 1 |
| Tiny UI in Lomiri and in all apps | qtmir + Qt5/Qt6 `ubuntumirclient` plugin report `GridUnit/8` (2.625) |
| OpenStore and older clicks do not start | `libxml2.so.2` + ICU 74 from Ubuntu 24.04 (SHA256 verified) |
| Links do nothing (indicator → *Bluetooth settings*, links from apps) | shim for the URL dispatcher (`liblomiri-app-launch` 0.2.0 dropped a function it still needs) |
| Settings → *Brightness & Display* does not open | mark a declared-but-never-implemented Qt slot weak in the panel plugin (1 byte) |

All binary patches look up their exact code location and print a `WARNING` instead of patching blindly when
UBports ships changed binaries. Details: the README inside the kit.

## Get the kit

- **Release:** download all `*.tar.zst.part*` files plus `*.sha256` from the latest release, then
  ```bash
  cat vayu-ubuntu-touch-26.04-flashkit.tar.zst.part* > vayu-ubuntu-touch-26.04-flashkit.tar.zst
  sha256sum -c vayu-ubuntu-touch-26.04-flashkit.tar.zst.sha256
  tar --zstd -xf vayu-ubuntu-touch-26.04-flashkit.tar.zst
  cd vayu-ubuntu-touch-26.04-flashkit && ./flash.sh      # phone in fastboot mode
  ```
- **Build on GitHub:** *Actions → "Build UT 26.04 flash kit" → Run workflow* (publishes a pre-release),
  or push a tag `v*`. Options: rootfs channel, fresh port CI build, own kernel 4.14.221.
- **Build locally** (Linux, no root, ~16 GB free):
  ```bash
  sudo apt install curl wget python3 unzip fakeroot e2fsprogs xz-utils zstd \
                   binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu
  ./build-2604.sh            # -> vayu-ubuntu-touch-26.04-flashkit/
  ./build-2604.sh --pack     # additionally .tar.zst + .sha256
  DEBUG=0 ./build-2604.sh    # image without the debug crash reporter
  ```

If the phone hangs at the splash: power + volume-down into fastboot, then `./debug-boot.sh` (in the kit) fetches
journal, Lomiri crash reports and pstore through a temporarily booted OrangeFox – nothing is flashed.

## Files

| File | Purpose |
|---|---|
| `build-2604.sh` | downloads all parts, builds `ubuntu.img` with the fixes, writes the kit incl. `flash.sh` and READMEs |
| `debug-boot.sh` | log/crash-report collector for a phone that does not reach the UI |
| `debug/vayucrash.c` | LD_PRELOAD crash reporter for Lomiri (debug builds) |
| `fixes/vayu-lal-compat.c` | URL dispatcher shim for the `liblomiri-app-launch` 0.2.0 ABI break |
| `fixes/elf-weaken-undef.py` | marks undefined dynamic symbols weak (Brightness & Display panel fix) |
| `kernel/` | optional own kernel build 4.14.190-halium → 4.14.221-perf |
| `.github/workflows/build.yml` | one-click build + release |

---

## Deutsch

Build-Skript und GitHub-Actions-Workflow für ein Flash-Kit mit **Ubuntu Touch 26.04** (UBports-Testkanal
`26.04-1.x` daily) für das Poco X3 Pro (**vayu**). vayu ist in diesem Kanal nicht enthalten – das Kit kombiniert das
generische Rootfs mit dem vayu-Community-Port (Halium 11) und repariert, was 26.04 auf vayu kaputt macht.

> ⚠️ Inoffizielle, frühe Testversion. Das Flashen löscht **alle Daten**. Für den Alltag ist das
> [24.04-Kit](https://github.com/dd6ds/ubtouch_xiaomi_poc_-x3_pro) die sicherere Wahl.

**Stand (13.11.2026, Build 471):** bootet bis zur Oberfläche, Einrichtungs-Assistent, Touch, Skalierung,
Einstellungen, Telefon, Browser, OpenStore und Bluetooth-Suche funktionieren. Die übrige Hardware ist unter 26.04 noch nicht neu getestet.

| Problem | Fix durch `build-2604.sh` |
|---|---|
| Hängt am Boot-Splash (Lomiri-Absturzschleife, kein adb) | qtmir: Display-Buffer über die Position zuordnen |
| Kleiner Bildausschnitt, Touch versetzt | qtmir: Mir-Ausgabefaktor bleibt 1 |
| Winzige Oberfläche in Lomiri und allen Apps | qtmir + Qt5/Qt6-Plugin `ubuntumirclient` melden `GridUnit/8` (2,625) |
| OpenStore und ältere Clicks starten nicht | `libxml2.so.2` + ICU 74 aus Ubuntu 24.04 (SHA256 geprüft) |
| Links tun nichts (Indikator → *Bluetooth-Einstellungen*, Links aus Apps) | Ersatz-Bibliothek für den URL-Dispatcher (`liblomiri-app-launch` 0.2.0 hat eine benötigte Funktion entfernt) |
| Einstellungen → *Helligkeit & Anzeige* öffnet nicht | einen deklarierten, aber nie implementierten Qt-Slot im Panel-Plugin als „weak“ markieren (1 Byte) |

**Kit bekommen:** fertiges Release herunterladen (Befehle oben), per *Actions → „Build UT 26.04 flash kit“ → Run workflow*
auf GitHub bauen (erstellt ein Pre-Release) oder lokal mit `./build-2604.sh` (Pakete siehe oben, kein root nötig).
Hängt das Telefon am Splash: Power + Leiser → Fastboot, dann `./debug-boot.sh` im Kit ausführen – es holt Journal,
Lomiri-Crash-Reports und pstore über ein temporär gestartetes OrangeFox, ohne etwas zu flashen.

Ausführliche Anleitung (Bootloader entsperren, Flashen, Fehlerbehebung): `README.de.md` im Kit.
