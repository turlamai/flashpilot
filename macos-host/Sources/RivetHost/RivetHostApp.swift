import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 560)
                .task { model.start() }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

enum BenchPhase: Equatable {
    case starting
    case ready
    case failed(String)
}

struct BenchTarget: Equatable {
    var product: String
    var version: String
    var mode: String
    var transport: String
    var ecu: String
    var fixturesPath: String?

    static func parse(_ statusJSON: String) -> BenchTarget? {
        guard let data = statusJSON.data(using: .utf8),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = doc["product"] as? String else { return nil }
        return BenchTarget(
            product: product,
            version: doc["version"] as? String ?? "",
            mode: doc["mode"] as? String ?? "",
            transport: doc["transport"] as? String ?? "",
            ecu: doc["ecu"] as? String ?? "",
            fixturesPath: doc["fixtures"] as? String
        )
    }

    var fixtureFiles: [String] {
        guard let fixturesPath, !fixturesPath.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: fixturesPath)
        else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }
}

struct PlanFinding: Identifiable, Equatable {
    let id = UUID()
    let severity: String
    let message: String
}

struct SegmentDetail: Identifiable, Equatable {
    let id = UUID()
    let address: UInt64
    let byteCount: Int
    let source: String
}

struct PlanRequirements: Equatable {
    var session: Int?
    var securityLevel: Int?
    var dataLength: Int?

    var transportLabel: String {
        guard let dataLength else { return "transport unspecified" }
        return dataLength <= 8 ? "Classic CAN" : "CAN FD (\(dataLength)-byte frames)"
    }

    var text: String {
        var parts: [String] = []
        if let session { parts.append(String(format: "session 0x%02X", session)) }
        if let securityLevel { parts.append("security level \(securityLevel)") }
        parts.append(transportLabel)
        return parts.joined(separator: " · ")
    }
}

struct PlanVerification: Equatable {
    var ok: Bool
    var file: String
    var findings: [PlanFinding]
    var segments: Int?
    var segmentDetails: [SegmentDetail]
    var requirements: PlanRequirements?
    var fingerprint: String?
    var expected: String?
    var match: Bool?
    var errorKind: String?
    var errorMessage: String?
    var rawJSON: String

    var errorCount: Int { findings.filter { $0.severity == "error" }.count }
    var warningCount: Int { findings.filter { $0.severity == "warning" }.count }

    static func parse(_ resultJSON: String) -> PlanVerification? {
        guard let data = resultJSON.data(using: .utf8),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = doc["ok"] as? Bool else { return nil }
        let findings = ((doc["findings"] as? [[String: Any]]) ?? []).map { item in
            PlanFinding(severity: item["severity"] as? String ?? "warning",
                        message: item["message"] as? String ?? "")
        }
        let segmentDetails = ((doc["segmentDetails"] as? [[String: Any]]) ?? []).compactMap { item in
            (item["address"] as? NSNumber).map {
                SegmentDetail(address: $0.uint64Value,
                              byteCount: (item["bytes"] as? NSNumber)?.intValue ?? 0,
                              source: item["source"] as? String ?? "inline")
            }
        }
        var requirements: PlanRequirements?
        if doc["session"] != nil || doc["dataLength"] != nil || doc["securityLevel"] != nil {
            requirements = PlanRequirements(
                session: (doc["session"] as? NSNumber)?.intValue,
                securityLevel: (doc["securityLevel"] as? NSNumber)?.intValue,
                dataLength: (doc["dataLength"] as? NSNumber)?.intValue)
        }
        if let error = doc["error"] as? [String: Any] {
            return PlanVerification(
                ok: ok, file: doc["file"] as? String ?? "", findings: findings,
                segments: doc["segments"] as? Int, segmentDetails: segmentDetails,
                requirements: requirements, fingerprint: doc["fingerprint"] as? String,
                expected: nil, match: nil,
                errorKind: error["kind"] as? String, errorMessage: error["message"] as? String,
                rawJSON: resultJSON)
        }
        return PlanVerification(
            ok: ok, file: doc["file"] as? String ?? "", findings: findings,
            segments: doc["segments"] as? Int, segmentDetails: segmentDetails,
            requirements: requirements, fingerprint: doc["fingerprint"] as? String,
            expected: doc["expected"] as? String, match: doc["match"] as? Bool,
            errorKind: nil, errorMessage: nil, rawJSON: resultJSON)
    }
}

struct ReadinessCheck: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let passed: Bool
    let severity: String
    let summary: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: BenchPhase = .starting
    @Published var backendStatus = "Starting embedded Racket CS…"
    @Published var target: BenchTarget?
    @Published var readinessOK: Bool?
    @Published var readinessRaw = ""
    @Published var readinessChecks: [ReadinessCheck] = []
    @Published var fixtures: [String] = []
    @Published var pickedPlanURL: URL?
    @Published var verification: PlanVerification?
    @Published var evidencePath = ""
    @Published var dtcResult = ""
    @Published var flashResult = ""
    @Published var flashLines: [String] = []
    @Published var busy = false

    private var backend: EmbeddedRacketBackend?

    var fixturesDirectory: URL? {
        guard let path = target?.fixturesPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var readinessSummary: String {
        guard case .ready = phase, let ok = readinessOK else { return "" }
        return ok
            ? "Bench preflight passed. The attached target answers UDS requests."
            : "Bench preflight failed. See the result payload for the failing check."
    }

    var dtcSummary: String {
        guard case .ready = phase, !dtcResult.isEmpty else { return "" }
        return dtcResult.contains("\"ok\":true")
            ? "DTC read succeeded. See the result payload."
            : "The target returned a negative or failed DTC response."
    }

    func start() {
        if phase == .ready { return }
        phase = .starting
        backendStatus = "Starting embedded Racket CS…"
        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)

            // Stream the audited flash workflow into the timeline; the
            // handler fires on a backend thread, so hop to the main actor.
            let startOnEvent: RivetClient.EventHandler? = { [weak self] name, value in
                guard name == "plan-progress" else { return }
                guard let event = try? RivetEvent.decode(name: name, value: value),
                      case let .plan_progress(json) = event else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.flashLines.append(json)
                }
            }

            // MainActor-isolated task owning the result; only the blocking
            // engine startup runs detached, with no self capture.
            Task { [backend] in
                do {
                    let status = try await Task.detached {
                        try backend.start(onEvent: startOnEvent)
                        return try await RivetAPI(client: backend.client).bench_status()
                    }.value
                    self.backend = backend
                    self.adopt(status: status)
                    self.backendStatus = "Embedded Racket CS is ready"
                    self.phase = .ready
                } catch {
                    self.backend = nil
                    self.backendStatus = "Backend error: \(error)"
                    self.phase = .failed("The verification engine could not start: \(error)")
                }
            }
        } catch {
            self.backend = nil
            backendStatus = "Configuration error: \(error)"
            phase = .failed("The embedded engine configuration is unusable: \(error)")
        }
    }

    private func adopt(status: String) {
        guard let parsed = BenchTarget.parse(status) else {
            phase = .failed("The engine reported an unreadable bench status.")
            return
        }
        target = parsed
        fixtures = parsed.fixtureFiles
    }

    func refreshStatus() {
        guard let backend, phase == .ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                let status = try await api.bench_status()
                adopt(status: status)
            } catch {
                backendStatus = "Status error: \(error)"
            }
        }
    }

    func validate() {
        guard let backend, phase == .ready, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let api = RivetAPI(client: backend.client)
                let raw = try await api.bench_validate()
                let doc = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                readinessOK = (doc?["ok"] as? NSNumber)?.boolValue ?? false
                readinessChecks = ((doc?["checks"] as? [[String: Any]]) ?? []).map { item in
                    ReadinessCheck(code: item["code"] as? String ?? "",
                                   passed: (item["passed"] as? NSNumber)?.boolValue ?? false,
                                   severity: item["severity"] as? String ?? "error",
                                   summary: item["summary"] as? String ?? "")
                }
                readinessRaw = raw
            } catch {
                readinessOK = false
                readinessChecks = []
                readinessRaw = "Error: \(error)"
            }
        }
    }

    var flashSummary: String {
        guard case .ready = phase, !flashResult.isEmpty else { return "" }
        return flashResult.contains("\"ok\":true")
            ? "Flash completed on the simulated bench. See the audited steps."
            : "The flash did not complete. See the failure evidence."
    }

    func flashPlan(at url: URL) {
        guard let backend, phase == .ready, !busy else { return }
        busy = true
        flashLines = []
        let path = (url.path as NSString).expandingTildeInPath
        Task {
            defer { busy = false }
            do {
                let api = RivetAPI(client: backend.client)
                flashResult = try await api.flash_plan(planPath: path)
            } catch {
                flashResult = "Error: \(error)"
            }
        }
    }

    func verifyPlan(at url: URL) {
        guard let backend, phase == .ready, !busy else { return }
        busy = true
        let path = (url.path as NSString).expandingTildeInPath
        Task {
            defer { busy = false }
            do {
                let api = RivetAPI(client: backend.client)
                let raw = try await api.verify_plan(planPath: path)
                verification = PlanVerification.parse(raw) ?? PlanVerification(
                    ok: false, file: path, findings: [], segments: nil, segmentDetails: [],
                    requirements: nil, fingerprint: nil,
                    expected: nil, match: nil, errorKind: "plan-unreadable",
                    errorMessage: "The engine returned an unreadable verification result.", rawJSON: raw)
            } catch {
                verification = PlanVerification(
                    ok: false, file: path, findings: [], segments: nil, segmentDetails: [],
                    requirements: nil, fingerprint: nil,
                    expected: nil, match: nil, errorKind: "plan-unreadable",
                    errorMessage: "\(error)", rawJSON: "")
            }
        }
    }

    func choosePlan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a flash plan to verify"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedPlanURL = url
        verifyPlan(at: url)
    }

    func exportEvidence() {
        guard let verification else { return }
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        let capturedAt = formatter.string(from: Date())
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FlashPilot", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
        guard let directory = support else {
            evidencePath = "Application Support is unavailable; evidence was not written."
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Millisecond stamps keep consecutive exports from clobbering
            // each other when verification and export run within a second.
            let stampFormatter = DateFormatter()
            stampFormatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
            let stamp = stampFormatter.string(from: Date())
            let url = directory.appendingPathComponent("flashpilot-evidence-\(stamp).json")
            var payload: [String: Any] = [
                "product": target?.product ?? "FlashPilot",
                "version": target?.version ?? RivetGeneratedConfig.version,
                "capturedAt": capturedAt,
                "verification": Self.parsedJSON(verification.rawJSON),
            ]
            if let target {
                payload["target"] = [
                    "mode": target.mode,
                    "transport": target.transport,
                    "ecu": target.ecu,
                ]
            }
            if let readiness = try? JSONSerialization.jsonObject(with: Data(readinessRaw.utf8)) {
                payload["readiness"] = readiness
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            evidencePath = url.path
        } catch {
            evidencePath = "Evidence export failed: \(error)"
        }
    }

    private static func parsedJSON(_ raw: String) -> Any {
        if let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
            return object
        }
        return raw
    }

    func readDtc() {
        guard let backend, phase == .ready, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let api = RivetAPI(client: backend.client)
                dtcResult = try await api.dtc_read()
            } catch {
                dtcResult = "Error: \(error)"
            }
        }
    }
}
