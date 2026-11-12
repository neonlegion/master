import SwiftUI
import AudioToolbox

// A compact mastering control surface bound to the AUParameterTree by
// identifier. Meters poll the audio unit's render-thread snapshot.
struct MasteringView: View {
    @ObservedObject var model: MeterModel
    let audioUnit: MasteringAUAudioUnit

    init(audioUnit: MasteringAUAudioUnit) {
        self.audioUnit = audioUnit
        self._model = ObservedObject(wrappedValue: MeterModel(audioUnit: audioUnit))
    }

    private func param(_ id: String) -> AUParameter? {
        audioUnit.parameterTree?.allParameters.first { $0.identifier == id }
    }

    private func slider(_ id: String, label: String, format: String = "%.1f") -> some View {
        Group {
            if let p = param(id) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(label).font(.caption)
                        Spacer()
                        Text(String(format: format, p.value)).font(.caption).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(p.value) },
                        set: { p.value = AUValue(Float($0)) }
                    ), in: Double(p.minValue)...Double(p.maxValue))
                }
            }
        }
    }

    private func toggle(_ id: String, label: String) -> some View {
        Group {
            if let p = param(id) {
                Toggle(label, isOn: Binding(
                    get: { p.value > 0.5 },
                    set: { p.value = $0 ? 1 : 0 }
                )).font(.caption)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("MasteringAU").font(.headline)

                GroupBox("Meters") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                        GridRow { Text("Integrated").font(.caption); Text(String(format: "%.2f LUFS", model.integrated)).monospacedDigit().font(.caption) }
                        GridRow { Text("Short-term").font(.caption); Text(String(format: "%.2f LUFS", model.shortTerm)).monospacedDigit().font(.caption) }
                        GridRow { Text("Momentary").font(.caption); Text(String(format: "%.2f LUFS", model.momentary)).monospacedDigit().font(.caption) }
                        GridRow { Text("LRA").font(.caption); Text(String(format: "%.2f LU", model.lra)).monospacedDigit().font(.caption) }
                        GridRow { Text("True peak").font(.caption); Text(String(format: "%.2f dBTP", model.tp)).monospacedDigit().font(.caption) }
                        GridRow { Text("Limiter GR").font(.caption); Text(String(format: "%.2f dB", model.gr)).monospacedDigit().font(.caption) }
                    }
                }

                GroupBox("Main") {
                    VStack { slider("inputGain", label: "Input dB"); slider("outputTrim", label: "Output dB"); toggle("bypass", label: "Bypass") }
                }
                GroupBox("High-Pass") {
                    VStack { toggle("hpEnable", label: "On"); slider("hpFreq", label: "Hz", format: "%.0f") }
                }
                GroupBox("EQ") {
                    ForEach(1...6, id: \.self) { b in
                        VStack(alignment: .leading) {
                            Text("Band \(b)").font(.caption.bold())
                            toggle("eq\(b)enable", label: "On")
                            slider("eq\(b)freq", label: "Hz", format: "%.0f")
                            slider("eq\(b)gain", label: "Gain dB")
                            slider("eq\(b)Q", label: "Q", format: "%.2f")
                        }
                    }
                }
                GroupBox("Stereo") {
                    VStack {
                        toggle("monoLowEnable", label: "Mono low"); slider("monoLowFreq", label: "Mono Hz", format: "%.0f")
                        slider("width", label: "Width dB")
                    }
                }
                GroupBox("Multiband") {
                    VStack(alignment: .leading) {
                        slider("mbXover1", label: "Xo1 Hz", format: "%.0f")
                        slider("mbXover2", label: "Xo2 Hz", format: "%.0f")
                        slider("mbXover3", label: "Xo3 Hz", format: "%.0f")
                        ForEach(1...4, id: \.self) { b in
                            VStack(alignment: .leading) {
                                Text("Band \(b)").font(.caption.bold())
                                toggle("mb\(b)enable", label: "On")
                                slider("mb\(b)thresh", label: "Thresh dB")
                                slider("mb\(b)ratio", label: "Ratio", format: "%.2f")
                                slider("mb\(b)attack", label: "Attack ms", format: "%.1f")
                                slider("mb\(b)release", label: "Release ms", format: "%.0f")
                                slider("mb\(b)makeup", label: "Makeup dB")
                            }
                        }
                    }
                }
                GroupBox("Saturation") {
                    VStack { toggle("satEnable", label: "On"); slider("satDrive", label: "Drive dB"); slider("satMix", label: "Mix %", format: "%.0f") }
                }
                GroupBox("Limiter") {
                    VStack {
                        toggle("limEnable", label: "On")
                        slider("limCeiling", label: "Ceiling dBTP")
                        slider("limLookahead", label: "Lookahead ms", format: "%.1f")
                        slider("limRelease", label: "Release ms", format: "%.0f")
                        toggle("ditherEnable", label: "Dither")
                    }
                }
            }
            .padding(10)
        }
    }
}

final class MeterModel: ObservableObject {
    @Published var momentary: Float = -120
    @Published var shortTerm: Float = -120
    @Published var integrated: Float = -120
    @Published var lra: Float = 0
    @Published var tp: Float = -120
    @Published var gr: Float = 0
    private var timer: Timer?
    private weak var au: MasteringAUAudioUnit?

    init(audioUnit: MasteringAUAudioUnit) {
        self.au = audioUnit
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let au = self.au else { return }
            let s = au.meterSnapshot
            DispatchQueue.main.async {
                self.momentary = s["momentaryLUFS"]?.floatValue ?? -120
                self.shortTerm = s["shortTermLUFS"]?.floatValue ?? -120
                self.integrated = s["integratedLUFS"]?.floatValue ?? -120
                self.lra = s["lraLU"]?.floatValue ?? 0
                self.tp = s["truePeakDbTP"]?.floatValue ?? -120
                self.gr = s["limiterGRDb"]?.floatValue ?? 0
            }
        }
    }
}
