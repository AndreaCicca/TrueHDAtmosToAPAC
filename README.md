# TrueHDAtmosToAPAC

Pipeline audio in tempo reale per **Apple TV 4K (tvOS)** e **macOS** che converte tracce **Dolby TrueHD Atmos** in **Apple Positional Audio Codec (`kAudioFormatAPAC`)**, preservando i canali **Height / Overhead** e attivando l'uscita **Dolby MAT 2.0 (Dolby Atmos)** via HDMI.

## Come funziona

Su tvOS non è permesso il passthrough diretto di Dolby TrueHD e la decodifica standard 7.1 LPCM perde i metadati 3D. Questa pipeline risolve il problema in 3 passaggi:

1. **Rendering 3D (`SpatialVBAPRenderer`)**: converte il bed 7.1 e gli oggetti 3D OAMD del 4° substream TrueHD in PCM a 12 canali (`Atmos 7.1.4`) o 16 canali (`Atmos 9.1.6`).
2. **Codifica APAC (`APACRealTimeTranscoder`)**: comprime il flusso in tempo reale nel formato di sistema `kAudioFormatAPAC` (`'apac'`).
3. **Output Dolby MAT 2.0 (`AtmosAPACAudioOutputEngine`)**: invia i pacchetti a `AVSampleBufferAudioRenderer`, che su Apple TV 4K abilita l'uscita Dolby Atmos via HDMI.

## Struttura del progetto

- `Sources/TrueHDAtmosToAPAC` — Libreria core (renderer 3D VBAP, encoder APAC, output engine e viste SwiftUI).
- `Sources/APACAtmosCLI` — Tool da riga di comando (`apac-atmos-poc`).
- `TVOSApp/TrueHDAtmosTVOS.xcodeproj` — App nativa tvOS per testare i singoli canali e le tracce spaziali.

## Avvio rapido

### App tvOS
Apri il progetto in Xcode e avvia su **Apple TV** o **Simulatore tvOS**:
```bash
open TVOSApp/TrueHDAtmosTVOS.xcodeproj
```

### CLI (macOS)
```bash
# Test della pipeline e verifica dei canali Height
swift run apac-atmos-poc

# Riproduzione audio live
swift run apac-atmos-poc --play
```
