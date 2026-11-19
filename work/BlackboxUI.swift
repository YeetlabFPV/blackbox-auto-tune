import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct AxisMetrics: Decodable {
    let events: Int
    let positive: Int?
    let negative: Int?
    let amplitude: Double?
    let overshoot: Double?
    let error: Double?
}

struct TrackingMetrics: Decodable {
    let seconds: Double
    let median_error: Double?
    let relative_error: Double?
    let near_motor_limit: Double
}

struct ResponseBand: Decodable {
    let gain: Double
    let phase_delay_ms: Double
}

struct AxisResponse: Decodable {
    let bands: [String: ResponseBand]
}

struct FilterSpectrum: Decodable {
    let low: Int
    let high: Int
    let windows: Int
    let frequency_hz: [Double]?
    let raw: [Double]?
    let gyro: [Double]?
    let dterm: [Double]?
}

struct FilterProfile: Decodable {
    let bands: [FilterSpectrum]
    let phase_delay_ms: [String: Double]
    let rpm_peak_correlation: Double?
}

struct EstimatedStep: Decodable {
    let curve: [Double]?
    let sample_ms: Double?
    let windows: Int?
    let overshoot: Double?
    let settling_ms: Double?
    let held_out_normalized_rmse: Double?
}

struct StopCoverage: Decodable {
    let count: Int
    let observed_positive: Int?
    let observed_negative: Int?
}

struct ShortEvent: Decodable {
    let seconds: Double
    let axis: String
    let hz: Double
    let gas: Double
    let rms: Double
}

struct RecoverySummary: Decodable {
    let count: Int
    let error_rms: Double
    let duration: Double
}

struct FlightMetrics: Decodable {
    let short_events: [ShortEvent]?
    let recovery_summary: [String: RecoverySummary]?
    let stop_summary: [String: StopCoverage]?
    let control_terms_available: Bool?
    let hz: Int
    let axes: [String: AxisMetrics]
    let windows: [String: Int]
    let noise: [String: [Double]]
    let tracking: [String: TrackingMetrics]?
    let response: [String: AxisResponse]?
    let estimated_steps: [String: EstimatedStep]?
    let filter_profile: FilterProfile?
}

struct LogMeasurement: Decodable {
    let file: String
    let metrics: FlightMetrics
}

struct LogSelection: Decodable {
    let reason: String
    let groups: Int
    let used: [String]
    let other: [String]
    let skipped_count: Int
}

struct SliderStep: Decodable {
    let instruction: String
    let reason: String
    let undo: String
}

struct Report: Decodable {
    let diagnostic: Bool?
    let slider_guidance: [String]?
    let relative_slider: SliderStep?
    let slider_comparison: String?

    var hasRecommendation: Bool { !changes.isEmpty || relative_slider != nil }
    let stage: Int
    let firmware: String
    let profile: Int?
    let config: [String: String]
    let metrics: FlightMetrics
    let changes: [String: String]
    let status: String
    let notes: [String]
    let blocked: Bool
    let logs: [LogMeasurement]?
    let selection: LogSelection?

    static func load(_ url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    var changeBlock: String { block(changes) }

    var undoBlock: String {
        block(config.filter { changes.keys.contains($0.key) })
    }

    private func block(_ values: [String: String]) -> String {
        guard !values.isEmpty else { return "" }
        let target = profile.map { ["profile \($0)"] } ?? []
        return (target + values.keys.sorted().compactMap { key in
            values[key].map { "set \(key) = \($0)" }
        }).joined(separator: "\n")
    }
}

extension Report {
    var coverageTips: [String] {
        let segments = logs?.map(\.metrics) ?? []
        var tips: [String] = []
        for axis in ["roll", "pitch"] {
            let moves = axis == "roll" ? "Rolls" : "Flips"
            if config["f_" + axis] != "0" {
                guard let weight = config["f_" + axis].flatMap(Int.init), weight >= 40 else { continue }
                if metrics.control_terms_available == false {
                    let tip = "Feedforward · Für die Zuordnung von Rückschlägen fehlen die PID-Term-Kanäle. Prüfe in den Blackbox-Einstellungen, ob die PID-Terme aufgezeichnet werden."
                    if !tips.contains(tip) { tips.append(tip) }
                } else if let stop = metrics.stop_summary?[axis],
                          stop.count >= 10 && min(stop.observed_positive ?? 0, stop.observed_negative ?? 0) >= 2 {
                    continue
                } else if metrics.stop_summary != nil {
                    tips.append("\(axis.capitalized) · Für den Feedforward-Vergleich fehlen auswertbare Stickstopps. Flieg ein paar \(moves) in beide Richtungen und lass den Stick am Ende zur Mitte zurück.")
                }
                continue
            }
            guard metrics.axes[axis]?.amplitude == nil else { continue }
            let samples = segments.compactMap { $0.axes[axis] }
            let positive = samples.map { $0.positive ?? 0 }.max() ?? 0
            let negative = samples.map { $0.negative ?? 0 }.max() ?? 0
            let reason: String
            if positive >= 3 && negative >= 3 {
                reason = "Beide Richtungen sind auf verschiedene Segmente verteilt. Flieg ein paar \(moves) in beide Richtungen im selben Flug."
            } else if positive >= 3 || negative >= 3 {
                reason = "Nur eine Richtung ist ausreichend erfasst. Wiederhole deine \(moves) auch in der Gegenrichtung im selben Flug."
            } else {
                reason = "Für die Messung des Überschwingens fehlen vergleichbare Stickimpulse. Flieg ein paar \(moves) in beide Richtungen und lass den Stick jeweils zur Mitte zurück."
            }
            tips.append("\(axis.capitalized) · P/D-Dämpfung separat prüfen. \(reason)")
        }
        for band in ["low", "mid"] where metrics.noise[band] == nil {
            let best = segments.map { $0.windows[band, default: 0] }.max()
            let range = band == "low" ? "20–40 %" : "40–65 %"
            let action = band == "low" ? "Flieg eine ruhige Gerade mit wenig Gas." : "Flieg eine ruhige Gerade mit etwas mehr, möglichst gleichmässigem Gas."
            let evidence = best.map { "Im besten Segment sind \($0) von 6 benötigten ruhigen Fenstern erfasst." } ?? "Es fehlen ruhige Messfenster."
            tips.append("Filter bei \(range) Gas · \(evidence) \(action)")
        }
        return tips
    }
}

private struct StepTrace: Identifiable {
    let id: String
    let values: [Double]
    let interval: Double
    let step: EstimatedStep
}

private struct StepPanel: View {
    let current: [LogMeasurement]
    let previous: [LogMeasurement]

    private func traces(_ logs: [LogMeasurement], _ axis: String, _ round: String) -> [StepTrace] {
        logs.enumerated().compactMap { index, log in
            guard let step = log.metrics.estimated_steps?[axis],
                  let curve = step.curve, curve.count > 1,
                  let interval = step.sample_ms, interval > 0 else { return nil }
            return StepTrace(id: "\(round) \(index + 1) · \(log.file)", values: curve, interval: interval, step: step)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aus Sollwert und Gyro geschätzte Reaktion. 100 % entspricht dem geschätzten Endwert. Für den Flugvergleich sollten Setup und Manöver vergleichbar sein.")
            ForEach(["roll", "pitch", "yaw"], id: \.self) { axis in
                let now = traces(current, axis, "Aktuell")
                if now.isEmpty {
                    Text("\(axis.capitalized) · Keine auswertbare Kurve im aktuellen Logmaterial")
                        .foregroundStyle(.secondary)
                } else {
                    let series = traces(previous, axis, "Vorher") + now
                    Text(axis.capitalized).font(.headline)
                    Chart {
                        RuleMark(y: .value("Endwert", 100)).lineStyle(StrokeStyle(dash: [4]))
                            .foregroundStyle(.secondary)
                        ForEach(series) { trace in
                            ForEach(trace.values.indices, id: \.self) { i in
                                LineMark(x: .value("Zeit (ms)", Double(i) * trace.interval),
                                         y: .value("Antwort (%)", 100 * trace.values[i]),
                                         series: .value("Segment", trace.id))
                                    .foregroundStyle(by: .value("Segment", trace.id))
                            }
                        }
                    }
                    .chartXAxisLabel("Millisekunden").chartYAxisLabel("Antwort (%)")
                    .frame(minHeight: 180)
                    ForEach(series) { trace in
                        let peak = trace.step.overshoot.map { String(format: "%.0f %%", 100 * $0) } ?? "offen"
                        let settling = trace.step.settling_ms.map { String(format: "%.0f ms", $0) } ?? "offen"
                        Text("\(trace.id) · Überschwingen \(peak) · Einschwingen \(settling)")
                    }
                }
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}

struct Result {
    let report: Report
    let url: URL
    let previous: Report?
}

enum Analyzer {
    static let output = Bundle.main.bundleURL.deletingLastPathComponent()
    static let work = output.deletingLastPathComponent().appendingPathComponent("work")

    static func run(logs: [URL], dump: URL?, previous: URL?, index: String, allowFilterOpening: Bool,
                    completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let firstLog = logs.first else { throw Failure("Wähle mindestens ein Rohlog.") }
                let files = FileManager.default
                let reports = work.appendingPathComponent("Flugberichte")
                try files.createDirectory(at: reports, withIntermediateDirectories: true)
                let baseline = try previous.map(Report.load)
                let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let report = reports.appendingPathComponent("Flug-\((baseline?.stage ?? 0) + 1)-\(date)-\(UUID().uuidString.prefix(8)).json")
                let python = work.appendingPathComponent("venv/bin/python")
                let decoder = work.appendingPathComponent("blackbox-tools/obj/blackbox_decode")
                guard files.isExecutableFile(atPath: python.path),
                      files.isExecutableFile(atPath: decoder.path) else {
                    throw Failure("Python-Umgebung oder Blackbox-Decoder fehlt. Öffne die App im ursprünglichen outputs-Ordner.")
                }
                let process = Process()
                process.executableURL = python
                process.arguments = [output.appendingPathComponent("bb_tune.py").path, firstLog.path,
                                     "--decoder", decoder.path, "--report", report.path]
                if allowFilterOpening { process.arguments?.append("--allow-filter-opening") }
                if let dump { process.arguments?.append(contentsOf: ["--dump", dump.path]) }
                for log in logs.dropFirst() {
                    process.arguments?.append(contentsOf: ["--additional-log", log.path])
                }
                if let previous { process.arguments?.append(contentsOf: ["--previous", previous.path]) }
                if !index.isEmpty { process.arguments?.append(contentsOf: ["--index", index]) }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let messages = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let text = String(decoding: messages, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw Failure(text.isEmpty ? "Die Auswertung wurde abgebrochen." : text)
                }
                let result = Result(report: try Report.load(report), url: report, previous: baseline)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}

@main
struct BlackboxApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .frame(minWidth: 850, minHeight: 630)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1050, height: 760)
    }
}

private enum TuneRating {
    case good, check, open, measured

    var title: String {
        switch self {
        case .good: "Unauffällig"
        case .check: "Prüfen"
        case .open: "Messung offen"
        case .measured: "Gemessen"
        }
    }

    var color: Color {
        switch self {
        case .good: Color(red: 0.42, green: 0.88, blue: 0.68)
        case .check: Color(red: 1, green: 0.72, blue: 0.39)
        case .open: Color(red: 0.62, green: 0.73, blue: 0.99)
        case .measured: Color(red: 0.72, green: 0.68, blue: 0.90)
        }
    }

    var icon: String {
        switch self {
        case .good: "checkmark.circle"
        case .check: "exclamationmark.circle"
        case .open: "circle.dashed"
        case .measured: "chart.xyaxis.line"
        }
    }
}

struct WorkspaceView: View {
    @State private var logs: [URL] = []
    @State private var dump: URL?
    @State private var previous: URL?
    @State private var baseline: Report?
    @State private var index = ""
    @State private var result: Result?
    @State private var completedRounds: [Int: Result] = [:]
    @State private var reviewing: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var copied: String?
    @State private var allowFilterOpening = false
    private let surface = Color(red: 0.095, green: 0.115, blue: 0.15)
    private let accent = Color(red: 0.50, green: 0.91, blue: 0.74)
    private let stages = ["Ausgangsmessung", "Nachmessen", "Verifizieren"]

    private var stage: Int { min(3, (baseline?.stage ?? 0) + 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.title2.weight(.semibold)).foregroundStyle(accent)
                Text("Blackbox Auto-Tune").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    NSWorkspace.shared.open(Analyzer.output.appendingPathComponent("Anleitung.md"))
                } label: {
                    Label("Flugprotokoll", systemImage: "book")
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(alignment: .leading) {
                LinearGradient(colors: [accent.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
            }
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(stages.enumerated()), id: \.offset) { offset, label in
                                let number = offset + 1
                                let selected = (reviewing ?? stage) == number
                                Button {
                                    reviewing = number == stage ? nil : number
                                } label: {
                                    HStack(spacing: 9) {
                                        Text("\(offset + 1)")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .frame(width: 24, height: 24)
                                            .background(selected ? accent : .white.opacity(0.08), in: Circle())
                                            .foregroundStyle(selected ? Color.black : Color.secondary)
                                        Text(label).fontWeight(selected ? .semibold : .regular)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(selected ? accent.opacity(0.09) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .disabled(number != stage && completedRounds[number] == nil)
                                .help(number == stage ? "Zur laufenden Runde" : "Auswertung dieser Runde ansehen")
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Blackbox-Rohlogs").font(.subheadline.weight(.semibold))
                            Button {
                                let selection = pickLogs()
                                if !selection.isEmpty {
                                    logs = selection
                                    result = nil
                                    error = nil
                                }
                            } label: {
                                Label(logs.isEmpty ? "Logs auswählen …" : "\(logs.count) ausgewählt · Ändern",
                                      systemImage: "waveform")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.controlSize(.large)
                            ForEach(logs, id: \.self) { file in
                                HStack {
                                    Text(file.lastPathComponent)
                                        .lineLimit(1).truncationMode(.middle).help(file.path)
                                    Spacer(minLength: 2)
                                    Button {
                                        logs.removeAll { $0 == file }
                                        result = nil
                                        error = nil
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Log entfernen")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        fileButton("CLI-Dump (optional)", dump, symbol: "doc.text") {
                            if let selected = pick(dumpText: true) {
                                dump = selected
                                error = nil
                                result = nil
                            }
                        }
                        if dump != nil {
                            Button("Ohne Dump auswerten") {
                                dump = nil
                                result = nil
                                error = nil
                            }.buttonStyle(.link)
                        }
                        fileButton("Flugbericht für Folgerunde (JSON)", previous, symbol: "clock.arrow.circlepath") {
                            guard let url = pick(json: true) else { return }
                            do {
                                let report = try Report.load(url)
                                guard report.stage < 3, !report.blocked else {
                                    throw Analyzer.Failure("Dieser Bericht kann keine weitere Auswertung starten.")
                                }
                                previous = url
                                baseline = report
                                completedRounds = [report.stage: Result(report: report, url: url, previous: nil)]
                                reviewing = nil
                                result = nil
                                error = nil
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        if previous != nil {
                            Button("Neue Messreihe") {
                                previous = nil
                                baseline = nil
                                completedRounds = [:]
                                reviewing = nil
                                result = nil
                                logs = []
                                dump = nil
                                index = ""
                                error = nil
                            }.buttonStyle(.link)
                        }
                        DisclosureGroup("Analyseoptionen") {
                            if stage == 1 {
                        Toggle("Filteröffnung als A/B-Test prüfen", isOn: $allowFilterOpening)
                            .font(.caption)
                            .help("Prüft in Runde 1, ob eine kleine Änderung am statischen Gyro-LPF1 mit deinen Logdaten begründet ist.")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Logsegment").font(.subheadline.weight(.semibold))
                            TextField("Alle Segmente", text: $index)
                                .textFieldStyle(.roundedBorder)
                                .help("Optional: Auf dieselbe Segmentnummer ab 1 in allen Dateien begrenzen.")
                        }
                        }
                        .onChange(of: index) { _ in result = nil; error = nil }
                        .onChange(of: allowFilterOpening) { _ in result = nil; error = nil }
                        Button {
                            start()
                        } label: {
                            HStack {
                                if busy { ProgressView().controlSize(.small) }
                                Text(busy ? "Analysiere …" : "Runde analysieren").fontWeight(.semibold)
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(accent)
                        .disabled(logs.isEmpty || busy)
                    }
                    .padding(20)
                }
                .frame(width: 274)
                .background(surface)
                .disabled(busy)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if reviewing == nil, let error {
                            Label {
                                Text(error).textSelection(.enabled)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        }
                        if let reviewing, let archived = completedRounds[reviewing] {
                            results(archived)
                        } else if let result {
                            results(result)
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(stage == 1 ? "Erster Testflug" : "Testflug für Runde \(stage)")
                                    .font(.largeTitle.weight(.semibold))
                                if stage > 1 {
                                    Text(baseline?.hasRecommendation == true
                                         ? "Übernimm den Vorschlag aus der letzten Runde. Wiederhole dieselben Passagen und Manöver mit vergleichbarem Tempo und Gas."
                                         : "Ergänze die fehlenden Manöver oder Gasbereiche aus der letzten Auswertung. Wiederhole auch die bisherigen Passagen für den Vergleich.")
                                }
                                Label("Ein Flug, ein Log · Flieg die Abschnitte nacheinander mit denselben Einstellungen.", systemImage: "doc")
                                Label("Flugmodus · Flieg den gesamten Test in Acro (Air).", systemImage: "switch.2")
                                Label("Filter · Flieg ein paar Sekunden ruhig geradeaus mit möglichst konstantem Gas. Wiederhole die Gerade mit etwas mehr Gas. Mach die Wendungen dazwischen. Ruhiges Schweben geht ebenfalls, liefert aber oft nur einen Gasbereich.", systemImage: "waveform")
                                Label("PID und Feedforward · Flieg mehrere einzelne Rolls nach links und rechts und Flips vorwärts und rückwärts. Bewege jeweils nur eine Achse, lass den Stick nach jeder Bewegung zur Mitte zurück und stabilisiere den Quad vor der nächsten. Halte etwas Gasreserve und vermeide Vollgas.", systemImage: "scope")
                                Label("Optional für Propwash · Sink mehrmals mit wenig Gas und möglichst wenig Roll- und Pitch-Eingabe. Fang den Quad jeweils mit einem kurzen, gleichmässigen Gasimpuls ab. Wiederhole ungefähr denselben Gaswechsel.", systemImage: "wind")
                                Text("Wähle danach die Blackbox-Logs aus. Du kannst mehrere Flüge mit denselben Einstellungen gemeinsam auswerten. Der CLI-Dump ist optional.")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 620, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(surface, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.06, green: 0.078, blue: 0.106))
    }

    private func fileButton(_ title: String, _ url: URL?, symbol: String,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Button(action: action) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(url == nil ? Color.secondary : accent)
                    Text(url?.lastPathComponent ?? "Datei auswählen …").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .help(url?.path ?? title)
        }
    }

    @ViewBuilder
    private func results(_ result: Result) -> some View {
        let report = result.report
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Runde \(report.stage) · \(stages[report.stage - 1])")
                    .font(.title2.weight(.semibold))
                let segments = report.logs?.count ?? 1
                let profile = report.profile.map { " · Profil \($0)" } ?? ""
                Text("\(report.firmware)\(profile) · \(report.metrics.hz) Hz · \(segments) \(segments == 1 ? "Segment" : "Segmente")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if reviewing != nil {
                Button("Weiter zu Runde \(stage)") { reviewing = nil }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .fixedSize()
            } else if report.stage < 3 && !report.blocked {
                Button("Runde \(report.stage + 1) vorbereiten") {
                    previous = result.url
                    baseline = report
                    logs = []
                    dump = nil
                    index = ""
                    self.result = nil
                    error = nil
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .fixedSize()
            }
        }
        Label(report.status, systemImage: report.diagnostic == true ? "info.circle" :
              report.blocked ? "exclamationmark.triangle" : !report.hasRecommendation ? "minus.circle" : "slider.horizontal.3")
            .font(.headline)
            .foregroundStyle(report.diagnostic == true || (!report.blocked && !report.hasRecommendation && report.slider_comparison == nil)
                             ? Color.secondary : report.blocked ? Color.orange : accent)
        if report.blocked && report.diagnostic != true,
           let reason = report.notes.first(where: {
               $0.hasPrefix("Für die Filterprüfung") || $0.hasPrefix("Die Manöver") ||
               $0.hasPrefix("Mindestens eine") || $0.hasPrefix("Starke Vibration")
           }) {
            Text(reason).foregroundStyle(.secondary)
        }
        if report.diagnostic == true {
            Text("Messwerte für diesen Vorab-Build. Die CLI-Zuordnung ist ungeprüft.")
                .foregroundStyle(.secondary)
        }
        if let comparison = report.slider_comparison {
            Text(comparison).font(.callout).textSelection(.enabled)
        }
        if let slider = report.relative_slider {
            VStack(alignment: .leading, spacing: 7) {
                Text(slider.instruction).font(.headline)
                Text(slider.reason)
                Text("Ändere nur diesen Slider im Betaflight Configurator. Merke dir den Ausgangswert und prüfe nach dem Testflug die Motorwärme.")
                    .foregroundStyle(.secondary)
                Text(slider.undo).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13).background(surface, in: RoundedRectangle(cornerRadius: 9))
        }
        if let guidance = report.slider_guidance, !guidance.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.changes.isEmpty ? "Slider-Status" : "Einstellempfehlung").font(.headline)
                ForEach(guidance, id: \.self) { Text($0) }
            }
        }
        if !report.changes.isEmpty {
            if report.profile == nil {
                let expected = report.changes.keys.sorted().compactMap { key in
                    report.config[key].map { "\(key) = \($0)" }
                }.joined(separator: "\n")
                DisclosureGroup("Aktuelle Werte im Betaflight-Profil prüfen") {
                    Text(expected).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            cliCard(report.blocked ? "Rücknahme der letzten Änderung" : "CLI-Vorschlag", report.changeBlock)
            Text("CLI am disarmten Quad einfügen, Antworten prüfen und separat mit save übernehmen.")
                .font(.caption).foregroundStyle(.secondary)
            if !report.blocked {
                DisclosureGroup {
                    cliCard("Ursprüngliche Werte", report.undoBlock)
                } label: {
                    Text("Rücknahmebefehle anzeigen").font(.subheadline)
                }
            }
        }
        Text("Tune-Übersicht").font(.title2.weight(.semibold)).padding(.top, 4)
        Text("Bewertet werden die Manöver und Gasbereiche im ausgewählten Flugmaterial.")
            .font(.callout).foregroundStyle(.secondary)
        Text("Sollwertfolge im Freiflug").font(.headline)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10, alignment: .top)], spacing: 10) {
            ForEach(["roll", "pitch", "yaw"], id: \.self) { axis in
                let tracking = report.logs?.compactMap { $0.metrics.tracking?[axis] } ?? []
                let gains = report.logs?.compactMap { $0.metrics.response?[axis]?.bands["5-12"]?.gain } ?? []
                metricCard(axis, tracking, gains, report)
            }
        }
        Text("P/D-Dämpfung").font(.headline)
        LazyVGrid(columns: ratingColumns, spacing: 10) {
            ForEach(["roll", "pitch"], id: \.self) { axis in
                dampingCard(axis, report, result.previous)
            }
        }
        let feedforwardTips = report.coverageTips.filter { $0.localizedCaseInsensitiveContains("Feedforward") }
        if !report.blocked && report.stage < 3 && !feedforwardTips.isEmpty {
            DisclosureGroup("Messhinweise für Feedforward") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(feedforwardTips, id: \.self) { Text($0) }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
        Text("Filter und Gasbereiche").font(.headline)
        LazyVGrid(columns: ratingColumns, spacing: 10) {
            ForEach(["low", "mid"], id: \.self) { band in
                filterCard(band, report)
            }
        }
        if let logs = report.logs {
            DisclosureGroup("Frequenzkarte und Gyro-Filterverzögerung") {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        if let profile = log.metrics.filter_profile {
                            spectrumPanel(log.file, profile)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            DisclosureGroup("Geschätzte Sprungantwort") {
                StepPanel(current: logs, previous: result.previous?.logs ?? [])
            }

        }
        if let logs = report.logs, logs.contains(where: { $0.metrics.short_events != nil }) {
            DisclosureGroup("Kurze Schwingungen und Abfangmanöver") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zeit ab Segmentbeginn. Auffälligkeiten bei kleinem Stickbefehl können durch Propwash, Regelung oder Mechanik entstehen.")
                        .foregroundStyle(.secondary)
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        if let events = log.metrics.short_events, !events.isEmpty {
                            Text(log.file).font(.headline)
                            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                                Text(String(format: "%.2f s · %@ · %.0f Hz · %.0f %% Gas · %.1f °/s RMS",
                                            event.seconds, event.axis.capitalized, event.hz, event.gas * 100, event.rms))
                            }
                        }
                    }
                    if logs.allSatisfy({ $0.metrics.short_events?.isEmpty != false }) {
                        Text("Keine auffälligen kurzen Schwingungen im geprüften Frequenzbereich.")
                    }
                    Text("Abfangen und Propwash").font(.headline)
                    let recoveries = report.metrics.recovery_summary ?? [:]
                    if recoveries.isEmpty {
                        Text("Weniger als drei auswertbare Abfangmanöver mit ähnlichem Gaswechsel.")
                    }
                    ForEach(recoveries.keys.sorted(), id: \.self) { gas in
                        if let current = recoveries[gas] {
                            let old = result.previous?.metrics.recovery_summary?[gas]
                            let value = String(format: "%.1f °/s RMS · %.1f s", current.error_rms, current.duration)
                            let before = old.map { String(format: "%.1f °/s RMS · %.1f s → ", $0.error_rms, $0.duration) } ?? ""
                            Text("Gas \(gas) · \(before)\(value) · \(current.count) aktuelle Manöver")
                        }
                    }
                    Text("Median des höchsten kurzen Roll-/Pitch-Sollwertfehlers nach dem Gasimpuls. Die Dauer zählt bis zum letzten Messfenster über 5 °/s, maximal 0,6 s.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 8)
            }
        }
        if let selection = report.selection {
            DisclosureGroup("Logauswahl · \(selection.used.count) verwendet")
            {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.reason)
                    ForEach(selection.used, id: \.self) { Text($0) }
                    if !selection.other.isEmpty {
                        Text("Andere Konfiguration oder Lograte").fontWeight(.semibold)
                        ForEach(selection.other, id: \.self) { Text($0) }
                    }
                    if selection.skipped_count > selection.other.count {
                        Text("Weitere übersprungene Segmente stehen in den Analysehinweisen.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.vertical, 8)
            }
        }
        if !report.notes.isEmpty {
            DisclosureGroup("Analysehinweise") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "info.circle").font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        } label: {
            Label("Bericht im Finder zeigen", systemImage: "folder")
                .font(.callout).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

    }

    private var ratingColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 2)
    }

    private func ratingCard<Detail: View>(_ title: String, _ rating: TuneRating, action: String,
                                          @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Label(rating.title, systemImage: rating.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(rating.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(rating.color.opacity(0.11), in: Capsule())
            detail().foregroundStyle(.secondary)
            Text(action).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(surface)
            RoundedRectangle(cornerRadius: 12).fill(
                LinearGradient(colors: [rating.color.opacity(0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(rating.color.opacity(0.23)))
    }

    private func metricCard(_ axis: String, _ tracking: [TrackingMetrics], _ gains: [Double], _ report: Report) -> some View {
        let measured = tracking.filter { $0.relative_error != nil }
        let seconds = measured.reduce(0) { $0 + $1.seconds }
        let error = measured.compactMap(\.relative_error).max()
        let rating: TuneRating
        let action: String
        let feedforwardKey = "f_" + axis
        if let target = report.changes[feedforwardKey], let current = report.config[feedforwardKey] {
            rating = .check
            action = report.blocked
                ? "Feedforward zurückstellen (\(current) → \(target))."
                : "Feedforward testen (\(current) → \(target)) und die Stickstopps wiederholen."
        } else if ["p", "d", "d_min", "d_max"].contains(where: { report.changes["\($0)_\(axis)"] != nil }) {
            rating = .check
            action = report.blocked ? "PID-Rücknahme oben prüfen." : "PID-Vorschlag oben testen und ähnliche Manöver wiederholen."
        } else if seconds < 2 || error == nil {
            rating = .open
            action = "Wiederhole ein paar zügige Bewegungen auf dieser Achse."
        } else if let error, error > 0.10 {
            rating = .check
            action = measured.contains { $0.near_motor_limit > 0.05 }
                ? "Wiederhole die Bewegung mit mehr Gasreserve."
                : "Wiederhole ähnliche Bewegungen. Prüfe die betroffene Achse im Folgeflug."
        } else {
            rating = .good
            action = "Einstellung beibehalten."
        }
        return ratingCard(axis.capitalized, rating, action: action) {
            if let error {
                Text(String(format: "Bis %.0f %% medianer Fehler · %.1f s Bewegung", error * 100, seconds))
                    .help("Höchster Median über die verwendeten Segmente bei Sollraten ab 120 °/s und verfügbarer Motorreserve.")
            }
            if let minGain = gains.min(), let maxGain = gains.max() {
                let range = maxGain - minGain >= 0.01
                    ? String(format: "%.2f–%.2f×", minGain, maxGain)
                    : String(format: "%.2f×", minGain)
                Text("Amplitudenverhältnis · \(range)")
                    .help("Geschätzte Reaktion im Freiflug bei 5–12 Hz. 1,00× entspricht gleicher Amplitude von Sollwert und Gyro.")
            }
        }
    }

    private func dampingCard(_ axis: String, _ report: Report, _ previous: Report?) -> some View {
        let value = report.metrics.axes[axis]
        let overshoot = value?.overshoot
        let old = previous?.metrics.axes[axis]?.overshoot
        let rating: TuneRating
        let action: String
        if let overshoot {
            if overshoot > 0.20 {
                rating = .check
                action = "Wiederhole die Bewegung und prüfe, ob der Rückschlag erneut auftritt."
            } else {
                rating = overshoot <= 0.10 ? .good : .measured
                action = overshoot <= 0.10 ? "Dämpfung beibehalten."
                    : "Vergleiche das Überschwingen bei ähnlichen Manövern im Folgeflug."
            }
        } else {
            rating = .open
            let prefix = "\(axis.capitalized) · P/D-Dämpfung separat prüfen. "
            let tip = report.coverageTips.first { $0.hasPrefix(prefix) }
            let moves = axis == "roll" ? "Rolls" : "Flips"
            action = tip.map { String($0.dropFirst(prefix.count)) } ??
                "Flieg ein paar \(moves) in beide Richtungen und lass den Stick jeweils zur Mitte zurück."
        }
        return ratingCard(axis.capitalized, rating, action: action) {
            if let overshoot {
                Text("Überschwingen \(percent(overshoot, old))")
            }
        }
    }

    private func spectrumPanel(_ name: String, _ profile: FilterProfile) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.subheadline.weight(.semibold))
            let delays = ["roll", "pitch"].compactMap { axis in
                profile.phase_delay_ms[axis].map { String(format: "%@ %.1f ms", axis.capitalized, $0) }
            }
            Text(delays.isEmpty ? "Gyro-Filterverzögerung: Datenabdeckung fehlt"
                 : "Geschätzte Gyro-Filterkette · " + delays.joined(separator: " · "))
            if let correlation = profile.rpm_peak_correlation {
                Text(String(format: "Rohgyro-Spitze ↔ eRPM · r = %.2f", correlation))
                    .help("Korrelation der dominanten Rohgyro-Spitze mit geloggter elektrischer Drehzahl. Ein Hinweis, kein Nachweis der mechanischen Ursache.")
            }
            if let frequencies = profile.bands.compactMap(\.frequency_hz).first {
                Text("25-Hz-Bänder · von \(Int(frequencies.first ?? 0)) bis \(Int(frequencies.last ?? 0)) Hz (Bandmitten)")
                    .foregroundStyle(.secondary)
                ForEach(["Rohgyro", "Gefiltertes Gyro", "D-Term"], id: \.self) { signal in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signal).fontWeight(.semibold)
                        let peak: Double = profile.bands.flatMap { (row: FilterSpectrum) -> [Double] in
                            signal == "D-Term" ? (row.dterm ?? []) : (row.raw ?? []) + (row.gyro ?? [])
                        }.max() ?? 1
                        ForEach(profile.bands, id: \.low) { row in
                            HStack(spacing: 3) {
                                Text("\(row.low)–\(row.high) %").frame(width: 65, alignment: .leading)
                                let values = signal == "Rohgyro" ? row.raw : signal == "Gefiltertes Gyro" ? row.gyro : row.dterm
                                if let values {
                                    ForEach(Array(values.enumerated()), id: \.offset) { i, value in
                                        Rectangle()
                                            .fill(accent.opacity(0.08 + 0.92 * min(1, sqrt(value / max(0.001, peak)))))
                                            .frame(height: 9)
                                            .help(String(format: "%.1f Hz · %.2f RMS", frequencies[i], value))
                                    }
                                } else {
                                    Text("Zu wenig Daten (\(row.windows) Fenster)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("Pro Segment haben beide Gyro-Karten dieselbe Farbskala in °/s RMS. Der D-Term hat eine eigene Skala. Hellere Felder zeigen stärkere Schwingungen.")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterCard(_ band: String, _ report: Report) -> some View {
        let values = report.metrics.noise[band] ?? []
        let range = band == "low" ? "20–40 %" : "40–65 %"
        let measured = values.count >= 8
        let strong = measured && (values[6...7].contains { $0 > 7 } || values[2...3].contains { $0 > 22 })
        let noisy = measured && (0..<2).contains { axis in
            values[axis] > 2.5 && values[4 + axis] > 4 && values[axis] > 0.20 * values[2 + axis]
        }
        let rating: TuneRating = !measured ? .open : (strong || noisy ? .check : .good)
        let action: String
        if !measured {
            let prefix = "Filter bei \(range) Gas · "
            action = report.coverageTips.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                ?? "Flieg eine ruhige Gerade in diesem Gasbereich."
        } else if strong {
            action = "Prüfe Props und Motoren und miss den Gasbereich erneut."
        } else if noisy {
            let filterChange = report.changes.keys.contains { $0.hasPrefix("dterm_lpf") }
                || report.relative_slider?.instruction.hasPrefix("D-Term Filter") == true
            action = filterChange
                ? "Teste die Filterempfehlung oben und wiederhole dieselbe Gerade."
                : "Wiederhole eine ruhige Gerade in diesem Gasbereich, um das Rauschen zu bestätigen."
        } else {
            action = "Filter für diesen Messbereich beibehalten."
        }
        return ratingCard("Gas \(range)", rating, action: action) {
            if measured {
                Text(String(format: "Gyro %.1f → %.1f °/s RMS", max(values[2], values[3]), max(values[0], values[1])))
                Text(String(format: "D-Term %.1f RMS", max(values[4], values[5])))
            }
        }
    }

    private func percent(_ value: Double?, _ old: Double?) -> String {
        guard let value else { return "–" }
        let current = String(format: "%.0f %%", value * 100)
        guard let old else { return current }
        return String(format: "%.0f %% → %@", old * 100, current)
    }

    private func cliCard(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text + "\n", forType: .string)
                    copied = label
                } label: {
                    Label(copied == label ? "Kopiert" : "Kopieren", systemImage: copied == label ? "checkmark" : "doc.on.doc")
                }
            }
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func pickLogs() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = logs.first?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func pick(json: Bool = false, dumpText: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if json {
            panel.allowedContentTypes = [.json]
            panel.directoryURL = Analyzer.work.appendingPathComponent("Flugberichte")
        } else if dumpText {
            panel.allowedContentTypes = [.plainText]
            panel.message = "Wähle die gespeicherte Betaflight-CLI-Ausgabe von dump (.txt)."
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start() {
        guard !logs.isEmpty else { return }
        reviewing = nil
        let segment = index.trimmingCharacters(in: .whitespacesAndNewlines)
        if !segment.isEmpty && (Int(segment) ?? 0) < 1 {
            error = "Gib eine Segmentnummer ab 1 ein."
            return
        }
        error = nil
        copied = nil
        result = nil
        busy = true
        Analyzer.run(logs: logs, dump: dump, previous: previous, index: segment, allowFilterOpening: allowFilterOpening) { response in
            busy = false
            switch response {
            case .success(let analysis):
                result = analysis
                completedRounds[analysis.report.stage] = analysis
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
