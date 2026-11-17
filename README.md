<h1 align="center">Rane SL3 macOS ARM Driver (Apple Silicon M1 / M2 / M3 / M4)</h1>

<p align="center">
  <strong>Native User-Space CoreAudio Driver + Serato DJ Pro 2.5.5 Bridge (<code>Sl3Api.framework</code>) for Rane SL3 on Modern Macs</strong><br>
  <em>Original idea & project by <strong>pepelee (PPLEE)</strong> — <a href="https://www.instagram.com/pepeleedj/">@pepeleedj</a> &nbsp;|&nbsp; Ultra-low-latency audio engine & CoreAudio architecture with <strong>Ben XO</strong> (<a href="https://github.com/ben-xo">@ben-xo</a>)</em>
</p>

<p align="center">
  <a href="https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver/raw/main/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip"><strong>⬇️ DOWNLOAD INSTALLER (.ZIP)</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver/raw/main/Installer/RaneSL3-macOS-Universal.pkg"><strong>📦 DOWNLOAD .PKG DIRECTLY</strong></a>
  &nbsp;|&nbsp;
  <a href="#-español-instrucciones-en-español"><strong>🇪🇸 LEER EN ESPAÑOL</strong></a>
</p>

---

## 🇬🇧 English

### Why does this exist?
When Apple transitioned to **Apple Silicon (M1 / M2 / M3 / M4)** and modern macOS versions, Rane and Serato discontinued support for the legendary **Rane SL3** DVS audio interface. Because the official Rane driver relied on a legacy Intel Kernel Extension (`.kext`), connecting an SL3 to a modern Mac simply did nothing—or required dangerous workarounds like disabling macOS System Integrity Protection (SIP).

**This project brings the Rane SL3 back to life on all Apple Silicon Macs (M1, M2, M3, M4 — Base, Pro, Max, Ultra) and modern macOS (Monterey, Ventura, Sonoma, Sequoia, and newer):**

* ✅ **Works natively with Serato DJ Pro 2.5.5** (the last Serato version that supports the Rane SL3 hardware—unlocks DVS `ABS` / `REL` / `INT` modes and `THRU` control).
* ✅ **NO SIP Disable Required & NO Reboot Required:** Runs 100% in user space via Apple's modern `AudioServerPlugIn` (CoreAudio HAL) and `IOUSBHost` frameworks, plus a custom Universal `Sl3Api.framework` user-space bridge.
* ✅ **Includes the SL 3 Control Panel app** (in Applications, macOS 13+) and a terminal control utility (`sl3panel`) to show each deck's **Phono / Line** switch (one per deck on the SL 3), toggle **Thru** per deck, set the **phono sensitivity**, and change sample rates (**44.1 kHz / 48 kHz**; 48 kHz by default, as Serato uses it).
* ✅ **Works as a 6-In / 6-Out (24-bit) CoreAudio Soundcard** in **Mixxx, Traktor, Ableton Live, Rekordbox, Logic Pro**, and system-wide macOS audio: channels 1–2 Aux, 3–4 Left deck, 5–6 Right deck.
* ✅ **Low-latency DVS engine, shared with the Rane SL 2 driver:** deep-scheduled late-write playback and early-read capture (`docs/SL3-AUDIO-ENGINE.md`). On the SL 2 it measures a ~9.3 ms DVS round trip at 64 frames; the SL 3's figures are still to be measured.
* ✅ **Output volume and mute** from the menu bar and the volume keys, and per channel in Audio MIDI Setup (the SL 3 has no volume control of its own, so the driver provides one). It applies to everything the SL 3 plays, **Serato's decks included**, and macOS remembers it: if your decks sound quiet in Serato, check the SL 3's volume.

---

### 🚀 Quick Installation (1-Click)

1. [**Download `Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver/raw/main/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip) and unzip it on your Mac.
2. Open Terminal and clear macOS Gatekeeper quarantine on the downloaded folder (type `xattr -cr ` with a space at the end, drag the unzipped folder into Terminal, and press **Enter**):
   ```bash
   xattr -cr ~/Downloads/Installer
   ```
3. Double-click **`Instalar-Rane-SL3.command`** (or right-click -> **Open** on **`RaneSL3-macOS-Universal.pkg`**).
4. Enter your Mac password when prompted.
5. **Done!** `coreaudiod` reloads automatically (no reboot needed). Plug in your Rane SL3 via USB!

#### Using with Serato DJ Pro 2.5.5
1. Download and install **Serato DJ Pro 2.5.5** from Serato's official archive (the final version with Rane SL3 support).
2. Connect your **Rane SL3** via USB and open Serato DJ Pro 2.5.5 (runs seamlessly via Rosetta 2 on M1/M2/M3/M4).
3. Serato will immediately recognize the SL3 and enable both decks with full DVS timecode control!

---

### 🔗 Also Available: Rane SL 2 & Rane SL 4 macOS ARM Drivers!
Own a **Rane SL 2** or **Rane SL 4**? Download their dedicated Apple Silicon (M1 / M2 / M3 / M4) drivers here:
* 🎛️ **Rane SL 2 Driver:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 4 Driver:** [pepeleedj/Rane-SL4-macOS-ARM-Driver](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver)

---
---

## 🇪🇸 Español (Instrucciones en Español)

### ¿Qué es este proyecto?
Con la llegada de los procesadores **Apple Silicon (M1 / M2 / M3 / M4)** y los nuevos sistemas macOS, las míticas tarjetas **Rane SL3** quedaron abandonadas porque el driver original de Rane dependía de una extensión de kernel antigua (`.kext`) para procesadores Intel.

**Este driver devuelve a la vida tu Rane SL3 en cualquier Mac moderno (M1, M2, M3, M4 y variantes Pro, Max, Ultra):**

* ✅ **Funciona nativamente con Serato DJ Pro 2.5.5** (la última versión de Serato compatible con Rane SL3; activa los modos DVS `ABS` / `REL` / `INT` y `THRU`).
* ✅ **SIN desactivar la seguridad del Mac (SIP) y SIN reiniciar:** Todo funciona en espacio de usuario mediante un plugin HAL de CoreAudio (`SL3Device.driver` sobre `IOUSBHost`) junto con un puente nativo Universal (`Sl3Api.framework`).
* ✅ **Incluye la app SL 3 Control Panel** (en Aplicaciones, macOS 13+) y la utilidad de control (`Panel-Control-SL3.command` / `sl3panel`) para ver el selector **Phono / Line** de cada plato, activar/desactivar **Thru** por plato, ajustar la **sensibilidad phono** y elegir entre **44.1 kHz y 48 kHz** (48 kHz por defecto).
* ✅ **Funciona como tarjeta de sonido de 6 Entradas y 6 Salidas (24-bit)** en **Ableton Live, Traktor, Mixxx, Rekordbox, Logic Pro** y el audio general de macOS.
* ✅ **Motor de audio de baja latencia, compartido con el driver de la Rane SL 2** (escritura tardía y lectura anticipada de la captura; en la SL 2 mide ~9.3 ms de ida y vuelta DVS a 64 frames; las cifras de la SL 3 están por medir).
* ✅ **Volumen y silencio de salida** desde la barra de menús y las teclas de volumen, y por canal en Configuración de Audio MIDI. Afecta a todo lo que suena por la SL 3, **incluidos los platos de Serato**: si suenan bajos en Serato, revisa el volumen de la SL 3.

---

### 🚀 Instalación Paso a Paso

Tienes dos formas de instalarlo (ambas instalan exactamente lo mismo y **NO requieren reiniciar el Mac**):

1. [**Descarga `Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver/raw/main/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip) y descomprímelo.
2. Si macOS bloquea los archivos descargados de Internet, abre la app **Terminal**, escribe `xattr -cr ` (con un espacio al final), arrastra la carpeta descomprimida dentro de la Terminal y pulsa **ENTER**:
   ```bash
   xattr -cr ~/Downloads/Installer
   ```
3. **Opción A (Automática en 1 clic):** Haz doble clic en **`Instalar-Rane-SL3.command`** (o clic derecho -> Abrir), introduce la contraseña de tu Mac y pulsa ENTER.
4. **Opción B (Asistente gráfico `.pkg`):** Haz clic derecho sobre **`RaneSL3-macOS-Universal.pkg`** -> **Abrir** (si macOS avisa que no está firmado por Apple, ve a *Ajustes del Sistema -> Privacidad y seguridad -> Abrir igualmente*).

#### Uso con Serato DJ Pro 2.5.5
* Instala **Serato DJ Pro 2.5.5** (última versión con soporte para Rane SL3).
* Conecta tu Rane SL3 por USB y abre Serato DJ Pro 2.5.5: detectará la tarjeta al instante y activará los dos platos con control por vinilo/CDJ (DVS).

#### Canales de Audio (6 Entradas / 6 Salidas a 24-bit, 44.1 / 48 kHz)
* **Canales 1–2:** Aux (Entrada / Salida Auxiliar)
* **Canales 3–4:** Left Deck (Plato / CDJ Izquierdo)
* **Canales 5–6:** Right Deck (Plato / CDJ Derecho)

---

### 🔗 También disponibles: Drivers para Rane SL 2 y Rane SL 4 (M1 / M2 / M3 / M4)
* 🎛️ **Rane SL 2:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 3:** [pepeleedj/Rane-SL3-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver)
* 🎛️ **Rane SL 4:** [pepeleedj/Rane-SL4-macOS-ARM-Driver](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver)

---

### 🛠️ Compilar desde el código fuente / Build from Source
Requires Xcode Command Line Tools (`xcode-select --install`):
```bash
make            # the driver, Sl3Api, sl3panel, sl3dump, sl3flash and the SL 3 Control Panel app
make install    # install a built driver over the installed package (DEBUG=1 for a debug build)
make package    # the installer package and zip, into build/
make hwtest ARGS="--loopback"   # the hardware tests (see tools/latency/README.md)
```
* `plugin/SL3Device.m`: the CoreAudio HAL AudioServerPlugIn (`SL3Device.driver`), driving the box over IOUSBHost.
* `tools/Sl3Api.m`: replacement `Sl3Api.framework`, matching Rane's 2.0.1f2, for Serato DJ Pro 2.5.5.
* `tools/sl3panel.m`, `tools/controlpanel/`: status and control, in Terminal and as an app.
* `tools/firmware/`, `tools/sl3dump.m`: firmware extraction from Rane's driver, over-USB flashing (not yet tested on an SL 3), EEPROM backup.
* `tools/latency/`, `tools/hwtest.sh`: latency, glitch and hardware tests.
* Docs: `docs/SL3-AUDIO-ENGINE.md` (design and bug catalogue), `docs/SL3-COMMANDS.md` (the box's protocol), `AGENTS.md` (for contributors).

---

### 🙌 Créditos y Licencia / Credits & License
* **Idea original, puente Serato (`Sl3Api.framework`), utilidad `sl3panel` e instalador macOS Universal:** **pepelee (PPLEE)** — Instagram: [@pepeleedj](https://www.instagram.com/pepeleedj/)
* **Motor de audio de baja latencia (del driver de la SL 2), controles de volumen/mute, `SL 3 Control Panel.app`, herramientas de firmware, pruebas de hardware y documentación del protocolo:** **Ben XO** — GitHub: [@ben-xo](https://github.com/ben-xo)
* **Base User-Space CoreAudio HAL Plugin (`OpenSL3`):** Basado en el proyecto open-source [OpenSL3](https://github.com/mrbrainz/OpenSL3) bajo licencia [GPL-3.0-or-later](LICENSE).
* *Disclaimer:* Proyecto independiente no afiliado con Rane ni Serato. "Rane", "SL3" y "Serato" son marcas registradas de sus respectivos propietarios.
