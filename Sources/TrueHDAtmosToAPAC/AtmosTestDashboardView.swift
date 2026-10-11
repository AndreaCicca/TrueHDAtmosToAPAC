import SwiftUI

/// Interfaccia di test essenziale basata esclusivamente sui componenti nativi di tvOS.
public struct AtmosTestDashboardView: View {
    @StateObject private var viewModel = AtmosTestViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // 1. Controlli Principali e Configurazione
                Section("Stato e Controlli") {
                    LabeledContent("Stato", value: viewModel.statusBannerText)

                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Label(
                            viewModel.isPlaying ? "Ferma Riproduzione" : "Avvia Riproduzione",
                            systemImage: viewModel.isPlaying ? "stop.fill" : "play.fill"
                        )
                    }

                    Picker("Layout Atmos", selection: $viewModel.targetLayout) {
                        ForEach(AtmosTargetLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }

                    Picker("Bitrate APAC", selection: $viewModel.bitRate) {
                        Text("768 kbps").tag(768_000)
                        Text("1024 kbps").tag(1_024_000)
                        Text("1280 kbps").tag(1_280_000)
                        Text("1536 kbps").tag(1_536_000)
                    }
                }

                // 2. Selezione Tracce di Test Spaziali
                Section("Tracce di Test") {
                    ForEach(AtmosTestTrackPreset.allCases) { preset in
                        Button {
                            viewModel.playPreset(preset)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.title)
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.selectedPreset == preset {
                                    Image(systemName: viewModel.isPlaying ? "speaker.wave.3.fill" : "checkmark")
                                }
                            }
                        }
                    }
                }

                // 3. Test Singolo Canale + Livelli RMS Nativo
                Section("Canali (\(viewModel.targetLayout.displayName)) — Seleziona per Isolare") {
                    let names = viewModel.targetLayout.channelNames
                    let heightSet = Set(viewModel.targetLayout.heightChannelIndices)

                    ForEach(0..<viewModel.targetLayout.channelCount, id: \.self) { ch in
                        let rms = ch < viewModel.channelRMS.count ? viewModel.channelRMS[ch] : 0.0
                        let isHeight = heightSet.contains(ch)
                        let role = (ch == 3) ? "LFE" : (isHeight ? "Height" : "Floor")

                        Button {
                            viewModel.selectAndSoloSpeaker(ch)
                        } label: {
                            HStack {
                                Text("\(ch + 1). \(names[ch]) (\(role))")
                                Spacer()
                                ProgressView(value: min(1.0, Double(rms) * 1.8), total: 1.0)
                                    .frame(width: 180)
                                Text(String(format: "%.3f", rms))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 4. Diagnostica Round-Trip APAC
                Section("Diagnostica Codec APAC") {
                    LabeledContent("Pacchetti APAC Codificati", value: "\(viewModel.encodedPackets)")
                    LabeledContent("Bitrate Effettivo", value: String(format: "%.1f kbps", viewModel.effectiveBitrateKbps))

                    Button {
                        viewModel.runAPACRoundTripDiagnostic()
                    } label: {
                        Label("Esegui Verifica Round-Trip APAC (Height Channels)", systemImage: "checkmark.circle")
                    }

                    if let passed = viewModel.roundTripPassed {
                        LabeledContent(
                            "Risultato Round-Trip",
                            value: passed ? " Canali Height Preservati" : "❌ Errore"
                        )
                        ForEach(viewModel.roundTripResults.filter { $0.isHeight }) { res in
                            LabeledContent(res.channelName, value: String(format: "RMS %.4f", res.decodedRMS))
                        }
                    }
                }
            }
            .navigationTitle("Test Tracce TrueHD Atmos → APAC")
        }
    }
}
