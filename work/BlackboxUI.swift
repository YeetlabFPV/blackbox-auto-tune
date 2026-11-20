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

struct ChirpResponse: Decodable {
    let axis: String
    let seconds: Double
    let duration: Double
    let frequency_hz: [Double]
    let gain_db: [Double]
    let phase_deg: [Double]
}

struct FlightMetrics: Decodable {
    let chirp_response: [ChirpResponse]?
    let chirp_seconds: Double?
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
    let kind: String?
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
    let english: Bool
    private func tr(_ german: String, _ englishText: String) -> String { english ? englishText : german }

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
            Text(tr("Aus Sollwert und Gyro geschätzte Reaktion. 100 % entspricht dem geschätzten Endwert. Für den Flugvergleich sollten Setup und Manöver vergleichbar sein.", "Response estimated from setpoint and gyro. 100% is the estimated final value. Use similar maneuvers and setups for comparison."))
            ForEach(["roll", "pitch", "yaw"], id: \.self) { axis in
                let now = traces(current, axis, tr("Aktuell", "Current"))
                if now.isEmpty {
                    Text(tr("\(axis.capitalized) · Keine auswertbare Kurve im aktuellen Logmaterial", "\(axis.capitalized) · No usable curve in the current logs"))
                        .foregroundStyle(.secondary)
                } else {
                    let series = traces(previous, axis, tr("Vorher", "Previous")) + now
                    Text(axis.capitalized).font(.headline)
                    Chart {
                        RuleMark(y: .value("Endwert", 100)).lineStyle(StrokeStyle(dash: [4]))
                            .foregroundStyle(.secondary)
                        ForEach(series) { trace in
                            ForEach(trace.values.indices, id: \.self) { i in
                                LineMark(x: .value(tr("Zeit (ms)", "Time (ms)"), Double(i) * trace.interval),
                                         y: .value(tr("Antwort (%)", "Response (%)"), 100 * trace.values[i]),
                                         series: .value("Segment", trace.id))
                                    .foregroundStyle(by: .value("Segment", trace.id))
                            }
                        }
                    }
                    .chartXAxisLabel(tr("Millisekunden", "Milliseconds")).chartYAxisLabel(tr("Antwort (%)", "Response (%)"))
                    .frame(minHeight: 180)
                    ForEach(series) { trace in
                        let peak = trace.step.overshoot.map { String(format: "%.0f %%", 100 * $0) } ?? tr("offen", "unavailable")
                        let settling = trace.step.settling_ms.map { String(format: "%.0f ms", $0) } ?? tr("offen", "unavailable")
                        Text(tr("\(trace.id) · Überschwingen \(peak) · Einschwingen \(settling)", "\(trace.id) · Overshoot \(peak) · Settling \(settling)"))
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
    static let resources = Bundle.main.resourceURL ?? output
    static let bundled = FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("python/bin/python3").path)
    static let reportFolder = (bundled
        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blackbox Auto-Tune")
        : work).appendingPathComponent("Flugberichte")
    static func guide(english: Bool) -> URL {
        (bundled ? resources : output).appendingPathComponent(english ? "Flight-Guide.md" : "Anleitung.md")
    }

    static func run(logs: [URL], dump: URL?, previous: URL?, index: String, allowFilterOpening: Bool,
                    completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let firstLog = logs.first else { throw Failure("Wähle mindestens ein Rohlog.") }
                let files = FileManager.default
                let reports = reportFolder
                try files.createDirectory(at: reports, withIntermediateDirectories: true)
                let baseline = try previous.map(Report.load)
                let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let report = reports.appendingPathComponent("Flug-\((baseline?.stage ?? 0) + 1)-\(date)-\(UUID().uuidString.prefix(8)).json")
                let python = bundled ? resources.appendingPathComponent("python/bin/python3") : work.appendingPathComponent("venv/bin/python")
                let decoder = bundled ? resources.appendingPathComponent("blackbox_decode") : work.appendingPathComponent("blackbox-tools/obj/blackbox_decode")
                guard files.isExecutableFile(atPath: python.path),
                      files.isExecutableFile(atPath: decoder.path) else {
                    throw Failure("Python-Umgebung oder Blackbox-Decoder fehlt. Öffne die App im ursprünglichen outputs-Ordner.")
                }
                let process = Process()
                process.executableURL = python
                process.arguments = [(bundled ? resources : output).appendingPathComponent("bb_tune.py").path, firstLog.path,
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

    func title(_ english: Bool) -> String {
        func tr(_ german: String, _ englishText: String) -> String { english ? englishText : german }
        return switch self {
        case .good: tr("Unauffällig", "Looks good")
        case .check: tr("Prüfen", "Check")
        case .open: tr("Messung offen", "More data needed")
        case .measured: tr("Gemessen", "Measured")
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
    @AppStorage("resultLanguage") private var language = "de"
    private var english: Bool { language == "en" }
    private func tr(_ german: String, _ englishText: String) -> String { english ? englishText : german }
    // Report strings remain compatible with existing German reports and CLI output.
    private static let reportPhrases: [(String, String)] = [
        ("Diagnose · Vorab-Firmware", "Diagnostics · Prerelease firmware"),
        ("CLI-Vorschlag zur Flugprüfung", "CLI suggestion for flight testing"),
        ("Slider-Schritt zur Flugprüfung", "Slider change for flight testing"),
        ("Keine Änderung abgeleitet", "No change recommended"),
        ("Keine klare Verschlechterung", "No clear degradation"),
        ("Kein klarer Nutzen", "No clear benefit"),
        ("Verbesserung im Vergleich", "Improvement observed"),
        ("Slider-Rücknahme empfohlen", "Restore the previous slider setting"),
        ("Slider-Vergleich offen", "Slider comparison pending"),
        ("Vergleich offen", "Comparison pending"),
        ("Rücknahme prüfen", "Review rollback"),
        ("Starke Vibration prüfen", "Investigate strong vibration"),
        ("Messung offen. Für die Beurteilung fehlen ruhige Passagen in einem Gasbereich.", "More data needed. See the suggested straight passes in the flight checklist."),
        ("Messung offen. Für den Master-Vergleich fehlen ruhige Gaspassagen oder gleichmässige Roll- und Pitch-Bewegungen mit Motorreserve.", "More data needed. See the flight checklist for the master multiplier comparison."),
        ("Vereinfachte PID-Slider deaktiviert.", "Simplified PID sliders are off."),
        ("Vereinfachter Filter-Slider deaktiviert.", "Simplified filter slider is off."),
        ("Aktuellen Wert beibehalten.", "Keep the current value."),
        ("Kurze Schwingungen bei kleinen Stickbefehlen erkannt.", "Short oscillations detected at low stick input."),
        ("Im Log fallen kurze Schwingungen ohne starken Stickbefehl auf.", "The log shows short oscillations at low stick input."),
        ("Die Messung begründet aktuell keinen Slider-Schritt.", "The measurements do not support a slider change yet."),
        ("Die Messung begründet aktuell keinen Master-Schritt.", "The measurements do not support a master multiplier change yet."),
        ("D-Term-Rauschen prüfen. Wiederhole ruhige Geraden im auffälligen Gasbereich.", "Check D-term noise. Repeat straight passes at the affected throttle level."),
        ("PID und Feedforward ·", "PID and feedforward ·"),
        ("Wiederhole die Manöver der betroffenen Achsen.", "Repeat the maneuvers on the affected axes."),
        ("Vergleiche Gyro-Rauschen und Filterverzögerung.", "Compare gyro noise and filter delay."),
        ("Vergleiche das Rauschen im selben Gasbereich.", "Compare noise in the same throttle range."),
        ("Für die nächste Runde den aktuellen CLI-Dump mitliefern.", "Include a current CLI dump in the next round."),
        ("Dyn. Minimum", "Dynamic minimum"),
        ("Dyn. Maximum", "Dynamic maximum"),
        ("Statisch", "Static"),
        ("Wiederholtes hochfrequentes D-Term-Rauschen. Flieg erneut ruhige Geraden im betroffenen Gasbereich.", "Repeated high-frequency D-term noise. Repeat straight passes at the affected throttle level."),
        ("Saubere Spektren, geloggtes RPM und messbare Gyro-Filterverzögerung. Wiederhole die ruhigen Geraden.", "Clean spectra, logged RPM, and measurable gyro filter delay. Repeat the straight passes."),
        ("Roll und Pitch bleiben bei gleichmässiger Drehung hinter dem Sollwert, bei vorhandener Motorreserve. Wiederhole dieselben Manöver.", "Roll and pitch lag during steady rotation with motor headroom. Repeat the same maneuvers."),
        ("Für den Master-Vergleich fehlen ähnlich schnelle Roll- und Pitch-Manöver.", "The master comparison needs roll and pitch maneuvers at similar rates."),
        ("Sollwertfehler Roll / Pitch ·", "Roll / pitch tracking error ·"),
        ("Für die Filterprüfung fehlen ruhige Fenster im zuvor auffälligen Gasbereich.", "The filter comparison needs steady passes at the previously affected throttle level."),
        ("D-Term-Rauschen ·", "D-term noise ·"),
        ("Für den Gyro-Vergleich fehlen vergleichbare Frequenzdaten oder Filterverzögerungen.", "The gyro comparison needs comparable spectra and filter-delay measurements."),
        ("Gyro-Filterverzögerung ·", "Gyro filter delay ·"),
        ("Für den Vergleich fehlen gemeinsame Gasbereiche.", "The flights lack overlapping throttle ranges."),
        ("Diese Segmente gehören zur selben aufgezeichneten Konfiguration.", "These segments have the same recorded settings."),
        ("Diese Gruppe bietet die beste vergleichbare Messabdeckung.", "This group has the best comparable measurement coverage."),
        ("Für diese Gruppe liegt ein begründeter Änderungsvorschlag vor.", "The measurements in this group support a tuning suggestion."),
        ("Übersprungen: ", "Skipped: "),
        ("Anderer aufgezeichneter Tune oder abweichende Lograte.", "Different recorded tune or log rate."),
        ("Vorab-Firmware · Messwerte ausgewertet. Für diese Firmware-Version ist die CLI-Zuordnung ungeprüft.", "Prerelease firmware · Measurements available. CLI mapping for this build is unverified."),
        ("Ohne Dump: Vor dem Einfügen das geflogene PID-Profil auswählen und die aktuellen Werte gegen die angezeigten Ausgangswerte prüfen.", "Without a dump, select the flown PID profile and check its current settings against the displayed original values before pasting commands."),
        ("Folgerunde ohne durchgehenden Dump-Abgleich: Die im Log belegten Werte wurden geprüft.", "Follow-up without dumps for both flights. The app checked the recorded settings."),
        ("Freiflug in ", "In-flight tracking in "),
        (" bei Sollrate ", " at setpoint rates "),
        (", mediane Abweichung ", ", median error "),
        (" nahe Motorausgangsgrenze", " near motor output limits"),
        ("Zu wenig aussagekräftige Testimpulse für eine P- oder D-Korrektur auf ", "Too few comparable stick inputs to suggest a P or D change on "),
        ("In den erfassten Gasbereichen wurde kein auffälliges hochfrequentes D-Term-Restgeräusch für eine Filteränderung gefunden.", "No elevated high-frequency D-term noise was found in the measured throttle ranges."),
        ("Restgeräusch in Gyro und D-Term: aktiven D-Term-Lowpass 1 vorsichtig absenken.", "Residual noise in gyro and D-term. Slightly lower the active D-term LPF1 cutoff."),
        ("Restgeräusch im D-Term. Der aktive LPF1 liegt bereits an der vorgesehenen Untergrenze.", "Residual D-term noise. The active LPF1 is already at the lower limit used by the app."),
        ("Überschwingen und anschließende Gegenbewegung bei niedrigem D-Term-Rauschen. D testweise erhöhen.", "Overshoot and rebound with low D-term noise. Try increasing D."),
        ("wiederholtes Überschwingen, P testweise senken.", "Repeated overshoot. Try lowering P."),
        ("anhaltender Rückstand bei geringem Überschwingen, P testweise erhöhen.", "Persistent lag with little overshoot. Try increasing P."),
        (" Stickstopps mit Rückschlag und überwiegendem Feedforward-Bremsanteil. Feedforward in einem kleinen A/B-Schritt senken und Stickstopps erneut messen.", " stick stops with bounce-back and predominantly feedforward braking. Lower feedforward slightly and repeat the stick stops."),
        ("Schmalbandige, nicht kommandierte Schwingung auf ", "Narrowband oscillation without a matching stick command on "),
        (". Mechanik, Filterung und Reglerschwingung prüfen. Gain-Änderungen für diese Achsen zurückgestellt.", ". Check the airframe, filtering, and control-loop oscillation. Gain changes on these axes are deferred."),
        ("A/B-Test: statischen Gyro-LPF1 leicht öffnen. Messung, Motorwärme und Flugverhalten danach erneut prüfen.", "A/B test. Relax static gyro LPF1 slightly, then recheck the measurements, motor temperature, and handling."),
        ("Filteröffnung zurückgestellt: Prüfe RPM-Abdeckung, saubere Spektren, messbare Verzögerung und aktiven statischen LPF1.", "Filter change deferred. Check RPM coverage, clean spectra, measurable delay, and whether static LPF1 is active."),
        ("Filter zuerst: Gains mit dem Folgeflug separat bewerten.", "Test the filter change first, then assess gains on the follow-up flight."),
        ("P/D-Balance: Nur Achsen mit nachweislich deaktiviertem Feedforward werden für P/D-Vorschläge berücksichtigt. Dämpfung und Tracking mit vergleichbaren Testflügen getrennt prüfen.", "P/D suggestions require evidence that feedforward is disabled on that axis. Assess damping and tracking in comparable flights."),
        ("Die Manöver oder Gasbereiche sind zu verschieden für eine Verifikation.", "The maneuvers or throttle ranges differ too much to verify the change."),
        ("Mindestens eine vergleichbare Kennzahl hat sich deutlich verschlechtert.", "At least one comparable measurement deteriorated substantially."),
        ("Im vergleichbaren Messbereich liegt keine deutliche Verschlechterung vor.", "No clear deterioration in the comparable measurements."),
        ("geschätzte Verzögerung der Gyro-Filterkette", "estimated gyro filter delay"),
        ("mediane Gegenrotation nach Stickstopp", "median reverse rotation after a stick stop"),
        ("Rauschen vergleichbar. Für eine Aussage zum Verzögerungsgewinn fehlt eine gemeinsame Messung.", "Noise is comparable. A shared measurement is needed to assess delay."),
        ("Starke Vibration in ", "Strong vibration in "),
        (". Props, Motoren und Aufbau prüfen.", ". Check props, motors, and the airframe."),
        ("Kein CLI-Vorschlag möglich. Prüfe die Hinweise zu den ausgewählten Segmenten.", "No usable tuning result. Check the notes for the selected segments."),
        ("Kein Betaflight-Rohlog erkannt.", "No raw Betaflight log detected."),
        ("Firmware ohne geprüfte CLI-Zuordnung: ", "Firmware without a verified CLI mapping: "),
        ("Wähle mindestens ein Rohlog.", "Select at least one Blackbox log."),
        ("Die Auswertung wurde abgebrochen.", "Analysis stopped."),
        ("Python-Umgebung oder Blackbox-Decoder fehlt. Öffne die App im ursprünglichen outputs-Ordner.", "Python or the Blackbox decoder is missing. Open the app from its original outputs folder."),
        (" gültige Impulse Roll ", " usable roll inputs "),
        ("ruhige Filterfenster", "steady filter windows"),
        ("Feedforward · Für die Zuordnung von Rückschlägen fehlen die PID-Term-Kanäle. Prüfe in den Blackbox-Einstellungen, ob die PID-Terme aufgezeichnet werden.", "Feedforward · Log the PID terms in Blackbox settings to identify the source of bounce-back."),
    ]

    private func reportText(_ text: String) -> String {
        guard english else { return text }
        return Self.reportPhrases.reduce(text) { result, phrase in
            result.replacingOccurrences(of: phrase.0, with: phrase.1)
        }.replacingOccurrences(of: #"Bei ([0-9.]+) belassen\."#, with: "Keep $1.", options: .regularExpression)
         .replacingOccurrences(of: #"(.+?) um ([0-9.]+) erhöhen"#, with: "Increase $1 by $2", options: .regularExpression)
         .replacingOccurrences(of: #"(.+?) um ([0-9.]+) senken"#, with: "Decrease $1 by $2", options: .regularExpression)
         .replacingOccurrences(of: #"([A-Za-z -]+ Multiplier) um ([0-9.]+) zurückstellen"#, with: "Undo the $2 change to $1", options: .regularExpression)
    }

    private var stages: [String] { [tr("Ausgangsmessung", "Baseline"), tr("Nachmessen", "Follow-up"), tr("Verifizieren", "Verification")] }

    private var stage: Int { min(3, (baseline?.stage ?? 0) + 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.title2.weight(.semibold)).foregroundStyle(accent)
                Text("Blackbox Auto-Tune").font(.title2.weight(.semibold))
                Spacer()
                Picker("Language / Sprache", selection: $language) {
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Button {
                    NSWorkspace.shared.open(Analyzer.guide(english: english))
                } label: {
                    Label(tr("Flugprotokoll", "Flight guide"), systemImage: "book")
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
                                .help(number == stage ? tr("Zur laufenden Runde", "Back to current round") : tr("Auswertung dieser Runde ansehen", "View this round's results"))
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Blackbox-Rohlogs", "Blackbox logs")).font(.subheadline.weight(.semibold))
                            Button {
                                let selection = pickLogs()
                                if !selection.isEmpty {
                                    logs = selection
                                    result = nil
                                    error = nil
                                }
                            } label: {
                                Label(logs.isEmpty ? tr("Logs auswählen …", "Select logs…") : tr("\(logs.count) ausgewählt · Ändern", "\(logs.count) selected · Change"),
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
                                    .accessibilityLabel(tr("Log entfernen", "Remove log"))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        fileButton(tr("CLI-Dump (optional)", "CLI dump (optional)"), dump, symbol: "doc.text") {
                            if let selected = pick(dumpText: true) {
                                dump = selected
                                error = nil
                                result = nil
                            }
                        }
                        if dump != nil {
                            Button(tr("Ohne Dump auswerten", "Analyze without dump")) {
                                dump = nil
                                result = nil
                                error = nil
                            }.buttonStyle(.link)
                        }
                        fileButton(tr("Flugbericht für Folgerunde (JSON)", "Previous flight report (JSON)"), previous, symbol: "clock.arrow.circlepath") {
                            guard let url = pick(json: true) else { return }
                            do {
                                let report = try Report.load(url)
                                guard report.stage < 3, !report.blocked else {
                                    throw Analyzer.Failure(tr("Dieser Bericht kann keine weitere Auswertung starten.", "This report cannot start a follow-up round."))
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
                            Button(tr("Neue Messreihe", "New tuning session")) {
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
                        DisclosureGroup(tr("Analyseoptionen", "Analysis options")) {
                            if stage == 1 {
                        Toggle(tr("Filteröffnung als A/B-Test prüfen", "Check whether to relax gyro filtering"), isOn: $allowFilterOpening)
                            .font(.caption)
                            .help(tr("Prüft in Runde 1, ob eine kleine Änderung am statischen Gyro-LPF1 mit deinen Logdaten begründet ist.", "In round 1, check whether the log supports a small change to static gyro LPF1."))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Logsegment", "Log segment")).font(.subheadline.weight(.semibold))
                            TextField(tr("Alle Segmente", "All segments"), text: $index)
                                .textFieldStyle(.roundedBorder)
                                .help(tr("Optional: Auf dieselbe Segmentnummer ab 1 in allen Dateien begrenzen.", "Optional. Use the same segment number in all logs, starting at 1."))
                        }
                        }
                        .onChange(of: index) { _ in result = nil; error = nil }
                        .onChange(of: allowFilterOpening) { _ in result = nil; error = nil }
                        Button {
                            start()
                        } label: {
                            HStack {
                                if busy { ProgressView().controlSize(.small) }
                                Text(busy ? tr("Analysiere …", "Analyzing…") : tr("Runde analysieren", "Analyze round")).fontWeight(.semibold)
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
                                Text(reportText(error)).textSelection(.enabled)
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
                                Text(stage == 1 ? tr("Erster Testflug", "First test flight") : tr("Testflug für Runde \(stage)", "Test flight for round \(stage)"))
                                    .font(.largeTitle.weight(.semibold))
                                if stage > 1 {
                                    Text(baseline?.hasRecommendation == true
                                         ? tr("Übernimm den Vorschlag aus der letzten Runde. Wiederhole dieselben Passagen und Manöver mit vergleichbarem Tempo und Gas.", "Apply the previous suggestion. Repeat the same passes and maneuvers at a similar speed and throttle.")
                                         : tr("Ergänze die fehlenden Manöver oder Gasbereiche aus der letzten Auswertung. Wiederhole auch die bisherigen Passagen für den Vergleich.", "Add the maneuvers or throttle ranges that were missing. Repeat the original passes for comparison."))
                                }
                                Label(tr("Ein Flug, ein Log · Flieg die Abschnitte nacheinander mit denselben Einstellungen.", "One flight, one log · Fly both parts in sequence with the same settings."), systemImage: "doc")
                                Label(tr("Flugmodus · Flieg den gesamten Test in Acro (Air).", "Flight mode · Fly the whole test in Acro (Air)."), systemImage: "switch.2")
                                Label(tr("Filter · Flieg ein paar Sekunden ruhig geradeaus mit möglichst konstantem Gas. Wiederhole die Gerade mit etwas mehr Gas. Mach die Wendungen dazwischen. Ruhiges Schweben geht ebenfalls, liefert aber oft nur einen Gasbereich.", "Filters · Fly straight for a few seconds at roughly steady throttle. Repeat with a little more throttle. Turn between passes. A steady hover usually covers only one throttle range."), systemImage: "waveform")
                                Label(tr("PID und Feedforward · Flieg mehrere einzelne Rolls nach links und rechts und Flips vorwärts und rückwärts. Bewege jeweils nur eine Achse, lass den Stick nach jeder Bewegung zur Mitte zurück und stabilisiere den Quad vor der nächsten. Halte etwas Gasreserve und vermeide Vollgas.", "PID and feedforward · Fly a few separate rolls and flips in each direction. Move one axis at a time, center the stick afterward, and let the quad settle before the next move. Leave some throttle in reserve."), systemImage: "scope")
                                Label(tr("Optional für Propwash · Sink mehrmals mit wenig Gas und möglichst wenig Roll- und Pitch-Eingabe. Fang den Quad jeweils mit einem kurzen, gleichmässigen Gasimpuls ab. Wiederhole ungefähr denselben Gaswechsel.", "Optional propwash test · Descend at low throttle with minimal roll or pitch input. Catch the descent with a short, steady throttle increase. Repeat at roughly the same throttle levels."), systemImage: "wind")
                                Text(tr("Wähle danach die Blackbox-Logs aus. Du kannst mehrere Flüge mit denselben Einstellungen gemeinsam auswerten. Der CLI-Dump ist optional.", "Load your Blackbox logs after the flight. You can analyze several flights together if they use the same settings. A CLI dump is optional."))
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
                    Text(url?.lastPathComponent ?? tr("Datei auswählen …", "Choose a file…")).lineLimit(1).truncationMode(.middle)
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
                Text(tr("Runde \(report.stage) · \(stages[report.stage - 1])", "Round \(report.stage) · \(stages[report.stage - 1])"))
                    .font(.title2.weight(.semibold))
                let segments = report.logs?.count ?? 1
                let profile = report.profile.map { tr(" · Profil \($0)", " · Profile \($0)") } ?? ""
                Text("\(report.firmware)\(profile) · \(report.metrics.hz) Hz · \(segments) \(segments == 1 ? "Segment" : tr("Segmente", "segments"))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if reviewing != nil {
                Button(tr("Weiter zu Runde \(stage)", "Return to round \(stage)")) { reviewing = nil }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .fixedSize()
            } else if report.stage < 3 && !report.blocked {
                Button(tr("Runde \(report.stage + 1) vorbereiten", "Prepare round \(report.stage + 1)")) {
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
        Label(reportText(report.status), systemImage: report.diagnostic == true ? "info.circle" :
              report.blocked ? "exclamationmark.triangle" : !report.hasRecommendation ? "minus.circle" : "slider.horizontal.3")
            .font(.headline)
            .foregroundStyle(report.diagnostic == true || (!report.blocked && !report.hasRecommendation && report.slider_comparison == nil)
                             ? Color.secondary : report.blocked ? Color.orange : accent)
        if report.blocked && report.diagnostic != true,
           let reason = report.notes.first(where: {
               $0.hasPrefix("Für die Filterprüfung") || $0.hasPrefix("Die Manöver") ||
               $0.hasPrefix("Mindestens eine") || $0.hasPrefix("Starke Vibration")
           }) {
            Text(reportText(reason)).foregroundStyle(.secondary)
        }
        if report.diagnostic == true {
            Text(tr("Messwerte für diesen Vorab-Build. Die CLI-Zuordnung ist ungeprüft.", "Measurements for this prerelease build. Its CLI parameter mapping is unverified."))
                .foregroundStyle(.secondary)
        }
        if let comparison = report.slider_comparison {
            Text(reportText(comparison)).font(.callout).textSelection(.enabled)
        }
        if let guidance = report.slider_guidance?.filter({ $0.hasPrefix("PID und Feedforward ·") }),
           !guidance.isEmpty {
            ForEach(guidance, id: \.self) { Text(reportText($0)) }
        }
        if !report.changes.isEmpty {
            if report.profile == nil {
                let expected = report.changes.keys.sorted().compactMap { key in
                    report.config[key].map { "\(key) = \($0)" }
                }.joined(separator: "\n")
                DisclosureGroup(tr("Aktuelle Werte im Betaflight-Profil prüfen", "Check current Betaflight profile values")) {
                    Text(expected).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            cliCard(report.blocked ? tr("Rücknahme der letzten Änderung", "Undo previous change") : tr("CLI-Vorschlag", "Suggested CLI commands"), report.changeBlock)
            Text(tr("CLI am disarmten Quad einfügen, Antworten prüfen und separat mit save übernehmen.", "Paste into the CLI while disarmed. Check the responses, then run save separately."))
                .font(.caption).foregroundStyle(.secondary)
            if !report.blocked {
                DisclosureGroup {
                    cliCard(tr("Ursprüngliche Werte", "Original values"), report.undoBlock)
                } label: {
                    Text(tr("Rücknahmebefehle anzeigen", "Show rollback commands")).font(.subheadline)
                }
            }
        }
        Text(tr("Tune-Übersicht", "Tune overview")).font(.title2.weight(.semibold)).padding(.top, 4)
        missingManeuvers(report)
        Text(tr("Sollwertfolge im Freiflug", "Setpoint tracking in flight")).font(.headline)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10, alignment: .top)], spacing: 10) {
            ForEach(["roll", "pitch", "yaw"], id: \.self) { axis in
                let tracking = report.logs?.compactMap { $0.metrics.tracking?[axis] } ?? []
                let gains = report.logs?.compactMap { $0.metrics.response?[axis]?.bands["5-12"]?.gain } ?? []
                metricCard(axis, tracking, gains, report)
            }
        }
        sliderCard("Master Multiplier", kind: "master", report)
        Text(tr("P/D-Dämpfung", "P/D damping")).font(.headline)
        LazyVGrid(columns: ratingColumns, spacing: 10) {
            ForEach(["roll", "pitch"], id: \.self) { axis in
                dampingCard(axis, report, result.previous)
            }
        }
        let feedforwardTips = report.coverageTips.filter { $0.hasPrefix("Feedforward ·") }
        if !report.blocked && report.stage < 3 && !feedforwardTips.isEmpty {
            DisclosureGroup(tr("Messhinweise für Feedforward", "Feedforward measurement tips")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(feedforwardTips, id: \.self) { Text(reportText($0)) }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
        Text(tr("Filter und Gasbereiche", "Filters and throttle ranges")).font(.headline)
        LazyVGrid(columns: ratingColumns, spacing: 10) {
            ForEach(["low", "mid"], id: \.self) { band in
                filterCard(band, report)
            }
        }
        LazyVGrid(columns: ratingColumns, spacing: 10) {
            sliderCard("Gyro Filter Multiplier", kind: "gyro", report, directLabel: "Gyro-LPF1")
            sliderCard("D-Term Filter Multiplier", kind: "dterm", report, directLabel: "D-Term-LPF1")
        }
        if let logs = report.logs, logs.contains(where: { ($0.metrics.chirp_seconds ?? 0) > 0 }) {
            DisclosureGroup(tr("Chirp-Frequenzantwort", "Chirp frequency response")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Betaflight-markierte Sweeps. Gain und Phase beschreiben die gemessene Regelantwort. CLI-Vorschläge verwenden die normalen Flugabschnitte.",
                            "Betaflight-marked sweeps. Gain and phase describe the measured closed-loop response. CLI suggestions use the ordinary flight sections."))
                        .foregroundStyle(.secondary)
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        let sweeps = log.metrics.chirp_response ?? []
                        if (log.metrics.chirp_seconds ?? 0) > 0 {
                            Text(log.file).font(.headline)
                            if sweeps.isEmpty {
                                Text(tr("Chirp erkannt. Für eine belastbare Kurve fehlen genügend gültige Frequenzpunkte.",
                                        "Chirp detected. Too few valid frequency points for a reliable curve."))
                            }
                            ForEach(Array(sweeps.enumerated()), id: \.offset) { _, sweep in
                                chirpChart(sweep)
                            }
                        }
                    }
                }.padding(.vertical, 8)
            }
        }
        if let logs = report.logs {
            DisclosureGroup(tr("Frequenzkarte und Gyro-Filterverzögerung", "Frequency map and gyro filter delay")) {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        if let profile = log.metrics.filter_profile {
                            spectrumPanel(log.file, profile)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            DisclosureGroup(tr("Geschätzte Sprungantwort", "Estimated step response")) {
                StepPanel(current: logs, previous: result.previous?.logs ?? [], english: english)
            }

        }
        if let logs = report.logs, logs.contains(where: { $0.metrics.short_events != nil }) {
            DisclosureGroup(tr("Kurze Schwingungen und Abfangmanöver", "Short oscillations and throttle recoveries")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Zeit ab Segmentbeginn. Auffälligkeiten bei kleinem Stickbefehl können durch Propwash, Regelung oder Mechanik entstehen.", "Times are relative to the segment start. Oscillations at low stick input may come from propwash, the controller, or the airframe."))
                        .foregroundStyle(.secondary)
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        if let events = log.metrics.short_events, !events.isEmpty {
                            Text(log.file).font(.headline)
                            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                                Text(String(format: "%.2f s · %@ · %.0f Hz · %.0f %% %@ · %.1f °/s RMS",
                                            event.seconds, event.axis.capitalized, event.hz, event.gas * 100, tr("Gas", "throttle"), event.rms))
                            }
                        }
                    }
                    if logs.allSatisfy({ $0.metrics.short_events?.isEmpty != false }) {
                        Text(tr("Keine auffälligen kurzen Schwingungen im geprüften Frequenzbereich.", "No short oscillations flagged in the tested frequency range."))
                    }
                    Text(tr("Abfangen und Propwash", "Throttle recovery and propwash")).font(.headline)
                    let recoveries = report.metrics.recovery_summary ?? [:]
                    if recoveries.isEmpty {
                        Text(tr("Weniger als drei auswertbare Abfangmanöver mit ähnlichem Gaswechsel.", "Fewer than three usable recoveries with similar throttle changes."))
                    }
                    ForEach(recoveries.keys.sorted(), id: \.self) { gas in
                        if let current = recoveries[gas] {
                            let old = result.previous?.metrics.recovery_summary?[gas]
                            let value = String(format: "%.1f °/s RMS · %.1f s", current.error_rms, current.duration)
                            let before = old.map { String(format: "%.1f °/s RMS · %.1f s → ", $0.error_rms, $0.duration) } ?? ""
                            Text(tr("Gas \(gas) · \(before)\(value) · \(current.count) aktuelle Manöver", "Throttle \(gas) · \(before)\(value) · \(current.count) current maneuvers"))
                        }
                    }
                    Text(tr("Median des höchsten kurzen Roll-/Pitch-Sollwertfehlers nach dem Gasimpuls. Die Dauer zählt bis zum letzten Messfenster über 5 °/s, maximal 0,6 s.", "Median peak short-window roll or pitch tracking error after adding throttle. Duration runs to the last window above 5 °/s, up to 0.6 s."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 8)
            }
        }
        if let selection = report.selection {
            DisclosureGroup(tr("Logauswahl · \(selection.used.count) verwendet", "Log selection · \(selection.used.count) used"))
            {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reportText(selection.reason))
                    ForEach(selection.used, id: \.self) { Text($0) }
                    if !selection.other.isEmpty {
                        Text(tr("Andere Konfiguration oder Lograte", "Different settings or log rate")).fontWeight(.semibold)
                        ForEach(selection.other, id: \.self) { Text($0) }
                    }
                    if selection.skipped_count > selection.other.count {
                        Text(tr("Weitere übersprungene Segmente stehen in den Analysehinweisen.", "See the analysis notes for other skipped segments."))
                    }
                }
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.vertical, 8)
            }
        }
        if !report.notes.isEmpty {
            DisclosureGroup(tr("Analysehinweise", "Analysis notes")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        Label(reportText(note), systemImage: "info.circle").font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        } label: {
            Label(tr("Bericht im Finder zeigen", "Show report in Finder"), systemImage: "folder")
                .font(.callout).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

    }

    @ViewBuilder
    private func missingManeuvers(_ report: Report) -> some View {
        let missingLow = report.metrics.noise["low"] == nil
        let missingMid = report.metrics.noise["mid"] == nil
        let roll = report.metrics.axes["roll"]?.overshoot == nil
        let pitch = report.metrics.axes["pitch"]?.overshoot == nil
        let masterOpen = report.slider_guidance?.contains { $0.hasPrefix("Master Multiplier · Messung offen") } == true
        let missingTracking = ["roll", "pitch", "yaw"].filter { axis in
            let tracking = report.logs?.compactMap { $0.metrics.tracking?[axis] } ?? []
            return tracking.filter { $0.relative_error != nil }.reduce(0) { $0 + $1.seconds } < 2
        }
        let needRoll = roll || masterOpen || missingTracking.contains("roll")
        let needPitch = pitch || masterOpen || missingTracking.contains("pitch")
        let needYaw = missingTracking.contains("yaw")
        if missingLow || missingMid || needRoll || needPitch || needYaw {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Was im nächsten Flug noch fehlt", "What to fly next")).font(.headline)
                if missingLow || missingMid {
                    let passes = missingLow && missingMid
                        ? tr("Flieg erst gemütlich geradeaus, dann eine zweite Gerade mit etwas mehr Gas.", "Fly one easy straight pass, then another with a little more throttle.")
                        : missingLow ? tr("Flieg eine gemütliche Gerade mit weniger Gas.", "Fly an easy straight pass at lower throttle.")
                        : tr("Flieg eine Gerade mit etwas mehr Gas als beim gemütlichen Vorwärtsflug.", "Fly a straight pass with a little more throttle than in easy forward flight.")
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(passes + tr(" Lass das Gas ein paar Sekunden ungefähr gleich und wende danach.", " Hold roughly the same throttle for a few seconds, then turn."))
                            Text(masterOpen ? tr("Für Gyro-Filter, D-Term-Filter und Master-Vergleich", "For gyro filters, D-term filters, and the master multiplier comparison") : tr("Für Gyro- und D-Term-Filter", "For gyro and D-term filters"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "waveform").foregroundStyle(TuneRating.open.color) }
                }
                if needRoll || needPitch {
                    let moves = needRoll && needPitch ? tr("ein paar einzelne Rolls und Flips", "a few separate rolls and flips") :
                        needRoll ? tr("ein paar einzelne Rolls", "a few separate rolls") : tr("ein paar einzelne Flips", "a few separate flips")
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("Flieg \(moves) in beide Richtungen. Lass den Stick nach jeder Bewegung zur Mitte zurück.", "Fly \(moves) in both directions. Center the stick after each move."))
                            Text(masterOpen ? tr("Für P/D-Dämpfung, Sollwertfolge und Master-Vergleich", "For P/D damping, tracking, and the master multiplier comparison") : tr("Für P/D-Dämpfung und Sollwertfolge", "For P/D damping and tracking"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "scope").foregroundStyle(TuneRating.open.color) }
                }
                if needYaw {
                    Label(tr("Dreh die Nase ein paarmal nach links und rechts. Das ergänzt die Yaw-Sollwertfolge.", "Yaw left and right a few times to fill in yaw tracking."),
                          systemImage: "arrow.left.and.right")
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var ratingColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 2)
    }

    private func ratingCard<Detail: View>(_ title: String, _ rating: TuneRating, action: String,
                                          @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Label(rating.title(english), systemImage: rating.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(rating.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(rating.color.opacity(0.11), in: Capsule())
            detail().foregroundStyle(.secondary)
            if !action.isEmpty { Text(action).fixedSize(horizontal: false, vertical: true) }
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

    @ViewBuilder
    private func sliderCard(_ title: String, kind: String, _ report: Report, directLabel: String? = nil) -> some View {
        let prefix = title + " · "
        let guidance = report.slider_guidance ?? []
        if let slider = report.relative_slider, slider.kind == kind ||
            (slider.kind == nil && slider.instruction.hasPrefix(title + " ")) {
            ratingCard(title, .check, action: reportText(slider.undo)) {
                Text(reportText(slider.instruction)).fontWeight(.semibold).foregroundStyle(.primary)
                Text(reportText(slider.reason))
                Text(tr("Ändere nur diesen Slider im Configurator. Merke dir den Ausgangswert und prüfe nach dem Flug die Motorwärme.", "Change only this slider in Configurator. Note the original value and check motor temperature after the flight."))
            }
        } else {
            let line = guidance.first { $0.hasPrefix(prefix) }
            let direct = directLabel.flatMap { label in guidance.first { $0.hasPrefix(label + " · ") } }
            let detail = line.map { String($0.dropFirst(prefix.count)) }
               ?? direct.map { tr("Vorschlag am Tiefpass. ", "Low-pass filter suggestion. ") + $0 }
               ?? (report.diagnostic == true ? tr("CLI-Zuordnung für diesen Build ungeprüft.", "CLI mapping for this build is unverified.")
                   : report.blocked ? tr("Slider-Bewertung zurückgestellt.", "Slider assessment deferred.")
                   : tr("Für diesen Bericht liegt keine Slider-Bewertung vor.", "This report has no slider assessment."))
            let rating: TuneRating = direct != nil || detail.contains("Schwingungen") || detail.hasPrefix("D-Term-Rauschen")
                ? .check : detail.hasPrefix("Messung offen") || (line == nil && direct == nil) ? .open : .measured
            ratingCard(title, rating, action: detail.hasPrefix("Messung offen") ? "" : reportText(detail)) { EmptyView() }
        }
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
                ? tr("Feedforward zurückstellen (\(current) → \(target)).", "Restore feedforward (\(current) → \(target)).")
                : tr("Feedforward testen (\(current) → \(target)) und die Stickstopps wiederholen.", "Test feedforward (\(current) → \(target)) and repeat the stick stops.")
        } else if ["p", "d", "d_min", "d_max"].contains(where: { report.changes["\($0)_\(axis)"] != nil }) {
            rating = .check
            action = report.blocked ? tr("PID-Rücknahme oben prüfen.", "Review the PID rollback above.") : tr("PID-Vorschlag oben testen und ähnliche Manöver wiederholen.", "Try the PID suggestion above and repeat similar maneuvers.")
        } else if seconds < 2 || error == nil {
            rating = .open
            action = ""
        } else if let error, error > 0.10 {
            rating = .check
            action = measured.contains { $0.near_motor_limit > 0.05 }
                ? tr("Wiederhole die Bewegung mit mehr Gasreserve.", "Repeat the movement with more throttle in reserve.")
                : tr("Wiederhole ähnliche Bewegungen. Prüfe die betroffene Achse im Folgeflug.", "Repeat similar movements and check this axis on the follow-up flight.")
        } else {
            rating = .good
            action = report.relative_slider?.kind == "master" && axis != "yaw"
                ? tr("Beim Master-Test die Sollwertfolge mit ähnlichen Manövern vergleichen.", "Repeat similar maneuvers to compare tracking during the master test.")
                : tr("Einstellung beibehalten.", "Keep the current setting.")
        }
        return ratingCard(axis.capitalized, rating, action: action) {
            if let error {
                Text(String(format: tr("Bis %.0f %% medianer Fehler · %.1f s Bewegung", "Up to %.0f %% median error · %.1f s of movement"), error * 100, seconds))
                    .help(tr("Höchster Median über die verwendeten Segmente bei Sollraten ab 120 °/s und verfügbarer Motorreserve.", "Highest segment median at setpoint rates of 120 °/s or more with motor headroom."))
            }
            if let minGain = gains.min(), let maxGain = gains.max() {
                let range = maxGain - minGain >= 0.01
                    ? String(format: "%.2f–%.2f×", minGain, maxGain)
                    : String(format: "%.2f×", minGain)
                Text(tr("Amplitudenverhältnis · \(range)", "Amplitude ratio · \(range)"))
                    .help(tr("Geschätzte Reaktion im Freiflug bei 5–12 Hz. 1,00× entspricht gleicher Amplitude von Sollwert und Gyro.", "Estimated response in flight at 5–12 Hz. A ratio of 1.00× means setpoint and gyro amplitudes match."))
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
                action = tr("Wiederhole die Bewegung und prüfe, ob der Rückschlag erneut auftritt.", "Repeat the movement and check whether bounce-back recurs.")
            } else {
                rating = overshoot <= 0.10 ? .good : .measured
                action = overshoot <= 0.10 ? tr("Dämpfung beibehalten.", "Keep the current damping.")
                    : tr("Vergleiche das Überschwingen bei ähnlichen Manövern im Folgeflug.", "Compare overshoot during similar maneuvers on the follow-up flight.")
            }
        } else {
            rating = .open
            action = ""
        }
        return ratingCard(axis.capitalized, rating, action: action) {
            if let overshoot {
                Text(tr("Überschwingen \(percent(overshoot, old))", "Overshoot \(percent(overshoot, old))"))
            }
        }
    }

    private func chirpChart(_ sweep: ChirpResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "%@ · %.1f s → %.1f s", sweep.axis.capitalized,
                        sweep.seconds, sweep.seconds + sweep.duration)).font(.subheadline)
            ForEach(["dB", "°"], id: \.self) { unit in
                let values = unit == "dB" ? sweep.gain_db : sweep.phase_deg
                Chart {
                    ForEach(Array(zip(sweep.frequency_hz, values).enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value(tr("Frequenz (Hz)", "Frequency (Hz)"), point.0),
                                  y: .value(unit, point.1))
                            .foregroundStyle(accent).symbolSize(13)
                    }
                }
                .chartXAxisLabel(tr("Frequenz (Hz)", "Frequency (Hz)"))
                .chartYAxisLabel(unit == "dB" ? "Gain (dB)" : tr("Phase (°)", "Phase (°)"))
                .frame(height: 125)
            }
        }
    }

    private func spectrumPanel(_ name: String, _ profile: FilterProfile) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.subheadline.weight(.semibold))
            let delays = ["roll", "pitch"].compactMap { axis in
                profile.phase_delay_ms[axis].map { String(format: "%@ %.1f ms", axis.capitalized, $0) }
            }
            Text(delays.isEmpty ? tr("Gyro-Filterverzögerung: Datenabdeckung fehlt", "Gyro filter delay unavailable")
                 : tr("Geschätzte Gyro-Filterkette · ", "Estimated gyro filter delay · ") + delays.joined(separator: " · "))
            if let correlation = profile.rpm_peak_correlation {
                Text(String(format: tr("Rohgyro-Spitze ↔ eRPM · r = %.2f", "Raw gyro peak ↔ eRPM · r = %.2f"), correlation))
                    .help(tr("Korrelation der dominanten Rohgyro-Spitze mit geloggter elektrischer Drehzahl. Ein Hinweis, kein Nachweis der mechanischen Ursache.", "Correlation of the dominant raw gyro peak with logged electrical RPM. Treat it as a clue to the source."))
            }
            if let frequencies = profile.bands.compactMap(\.frequency_hz).first {
                Text(tr("25-Hz-Bänder · von \(Int(frequencies.first ?? 0)) bis \(Int(frequencies.last ?? 0)) Hz (Bandmitten)", "25 Hz bands · \(Int(frequencies.first ?? 0)) to \(Int(frequencies.last ?? 0)) Hz (band centers)"))
                    .foregroundStyle(.secondary)
                ForEach(["Rohgyro", "Gefiltertes Gyro", "D-Term"], id: \.self) { signal in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signal == "Rohgyro" ? tr("Rohgyro", "Raw gyro") : signal == "Gefiltertes Gyro" ? tr("Gefiltertes Gyro", "Filtered gyro") : signal).fontWeight(.semibold)
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
                                    Text(tr("Zu wenig Daten (\(row.windows) Fenster)", "Too little data (\(row.windows) windows)")).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text(tr("Pro Segment haben beide Gyro-Karten dieselbe Farbskala in °/s RMS. Der D-Term hat eine eigene Skala. Hellere Felder zeigen stärkere Schwingungen.", "In each segment, both gyro maps share a color scale in °/s RMS. D-term uses a separate scale. Brighter cells indicate stronger oscillations."))
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
            action = ""
        } else if strong {
            action = tr("Prüfe Props und Motoren und miss den Gasbereich erneut.", "Check the props and motors, then repeat this throttle range.")
        } else if noisy {
            let filterChange = report.changes.keys.contains { $0.hasPrefix("dterm_lpf") }
                || report.relative_slider?.instruction.hasPrefix("D-Term Filter") == true
            action = filterChange
                ? tr("Teste die Filterempfehlung und wiederhole dieselbe Gerade.", "Try the filter suggestion and repeat the same straight pass.")
                : tr("Wiederhole eine ruhige Gerade in diesem Gasbereich, um das Rauschen zu bestätigen.", "Repeat a steady straight pass at this throttle to confirm the noise.")
        } else {
            action = ["gyro", "dterm"].contains(report.relative_slider?.kind ?? "")
                ? tr("Miss diesen Gasbereich nach dem Slider-Test erneut.", "Repeat this throttle range after testing the slider change.")
                : tr("Filter für diesen Messbereich beibehalten.", "Keep the current filters for this throttle range.")
        }
        return ratingCard(tr("Gas \(range)", "Throttle \(range)"), rating, action: action) {
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
                    Label(copied == label ? tr("Kopiert", "Copied") : tr("Kopieren", "Copy"), systemImage: copied == label ? "checkmark" : "doc.on.doc")
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
            panel.directoryURL = Analyzer.reportFolder
        } else if dumpText {
            panel.allowedContentTypes = [.plainText]
            panel.message = tr("Wähle die gespeicherte Betaflight-CLI-Ausgabe von dump (.txt).", "Select the saved Betaflight CLI dump (.txt).")
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start() {
        guard !logs.isEmpty else { return }
        reviewing = nil
        let segment = index.trimmingCharacters(in: .whitespacesAndNewlines)
        if !segment.isEmpty && (Int(segment) ?? 0) < 1 {
            error = tr("Gib eine Segmentnummer ab 1 ein.", "Enter a segment number starting at 1.")
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
