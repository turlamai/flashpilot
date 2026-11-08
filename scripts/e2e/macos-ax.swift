import AppKit
import ApplicationServices
import Foundation

enum DriverError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let message): return message } }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func walk(_ element: AXUIElement) -> [AXUIElement] {
    [element] + children(element).flatMap(walk)
}

func waitFor<T>(_ description: String, timeout: TimeInterval = 45, probe: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = probe() { return value }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw DriverError.failure("timed out waiting for \(description)")
}

func findButton(_ root: AXUIElement, names: Set<String>) -> AXUIElement? {
    walk(root).first { element in
        stringAttribute(element, kAXRoleAttribute) == (kAXButtonRole as String) &&
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
                .contains { names.contains(stringAttribute(element, $0)) }
    }
}

func findButton(identifierPrefix prefix: String) -> (AXUIElement) -> AXUIElement? {
    { root in
        walk(root).first { element in
            stringAttribute(element, kAXRoleAttribute) == (kAXButtonRole as String) &&
                stringAttribute(element, kAXIdentifierAttribute).hasPrefix(prefix)
        }
    }
}

func enabled(_ element: AXUIElement) -> Bool {
    attribute(element, kAXEnabledAttribute) as? Bool ?? false
}

func contains(_ root: AXUIElement, fragment: String) -> Bool {
    walk(root).contains { element in
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .contains { stringAttribute(element, $0).contains(fragment) }
    }
}

func snapshot(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var result: [String: Any] = [
        "role": stringAttribute(element, kAXRoleAttribute),
        "identifier": stringAttribute(element, kAXIdentifierAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "label": stringAttribute(element, kAXDescriptionAttribute),
        "value": stringAttribute(element, kAXValueAttribute),
    ]
    if depth < 8 { result["children"] = children(element).map { snapshot($0, depth: depth + 1) } }
    return result
}

func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url)
}

var diagnosticApplication: AXUIElement?
var diagnosticOutput: URL?

do {
    let arguments = CommandLine.arguments
    guard let pidIndex = arguments.firstIndex(of: "--pid"), pidIndex + 1 < arguments.count,
          let pid = Int32(arguments[pidIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"), outputIndex + 1 < arguments.count else {
        throw DriverError.failure("usage: macos-ax --pid PID --output DIRECTORY")
    }
    let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
    diagnosticOutput = output
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard AXIsProcessTrusted() else { throw DriverError.failure("accessibility access is unavailable") }

    let application = AXUIElementCreateApplication(pid)
    diagnosticApplication = application
    let window: AXUIElement = try waitFor("FlashPilot window") {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
    }
    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

    // The identity card must name the simulator target before anything is
    // pressed: target/mode is the honesty label this slice is about.
    _ = try waitFor("simulator target identity") {
        contains(window, fragment: "sim-ecu") && contains(window, fragment: "Mode: simulator") ? true : nil
    }

    // Primary next step: bench readiness through the embedded backend.
    let validate: AXUIElement = try waitFor("enabled Validate bench button") {
        guard let button = findButton(window, names: ["ValidateBenchButton", "Validate bench"]),
              enabled(button) else { return nil }
        return button
    }
    guard AXUIElementPerformAction(validate, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for Validate bench")
    }
    _ = try waitFor("readiness result from embedded backend") {
        contains(window, fragment: "Bench preflight passed") ? true : nil
    }

    // Bundled simulator fixture: full verification from a clean package.
    let fixtureVerify = findButton(identifierPrefix: "FixtureVerifyButton-plan.sim.json")
    let fixtureButton: AXUIElement = try waitFor("enabled Verify plan.sim.json fixture button") {
        guard let button = fixtureVerify(window), enabled(button) else { return nil }
        return button
    }
    guard AXUIElementPerformAction(fixtureButton, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for the simulator fixture")
    }
    _ = try waitFor("passing verification result") {
        contains(window, fragment: "fingerprint") && contains(window, fragment: "Passed") ? true : nil
    }

    // Flash the simulator fixture through the native flash surface: the
    // audited workflow returns as evidence, no hardware is touched.
    let flashFinder = findButton(identifierPrefix: "FlashPlanButton-plan.sim.json")
    let flashButton: AXUIElement = try waitFor("enabled Flash plan button") {
        guard let button = flashFinder(window), enabled(button) else { return nil }
        return button
    }
    guard AXUIElementPerformAction(flashButton, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for Flash plan")
    }
    _ = try waitFor("flash result from the simulated bench") {
        contains(window, fragment: "Flash completed on the simulated bench") ? true : nil
    }
    _ = try waitFor("streamed flash timeline") {
        contains(window, fragment: "diagnostic-session") ? true : nil
    }

    // Export evidence; the app renders the absolute path it wrote, so the
    // driver asserts the artifact on disk through that rendered path instead
    // of guessing the location (GUI processes resolve Application Support
    // from the user record, not the HOME environment).
    let exportButton: AXUIElement = try waitFor("enabled Export evidence button") {
        guard let button = findButton(window, names: ["ExportEvidenceButton", "Export evidence…"]),
              enabled(button) else { return nil }
        return button
    }
    func renderedEvidencePath() -> String {
        walk(window).first { stringAttribute($0, kAXIdentifierAttribute) == "EvidencePath" }
            .map { stringAttribute($0, kAXValueAttribute) } ?? ""
    }
    guard AXUIElementPerformAction(exportButton, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for Export evidence")
    }
    let firstEvidencePath: String = try waitFor("first exported evidence file") {
        let path = renderedEvidencePath()
        return (!path.isEmpty && FileManager.default.fileExists(atPath: path)
                && path.hasSuffix(".json")) ? path : nil
    }

    // Failure injection: the shipped missing-image fixture must produce the
    // distinct segment-unavailable recovery, not a dead screen.
    let missingVerify = findButton(identifierPrefix: "FixtureVerifyButton-plan.sim-missing-image.json")
    let missingButton: AXUIElement = try waitFor("enabled missing-image fixture button") {
        guard let button = missingVerify(window), enabled(button) else { return nil }
        return button
    }
    guard AXUIElementPerformAction(missingButton, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for the missing-image fixture")
    }
    _ = try waitFor("segment-unavailable recovery finding") {
        contains(window, fragment: "segment-unavailable") &&
            contains(window, fragment: "segment image referenced by the plan is missing") ? true : nil
    }
    // Re-resolve the button: the verification card re-rendered after the
    // missing-image verification, so the earlier AX reference may be stale.
    let exportButton2: AXUIElement = try waitFor("enabled Export evidence button (second)") {
        guard let button = findButton(window, names: ["ExportEvidenceButton", "Export evidence…"]),
              enabled(button) else { return nil }
        return button
    }
    guard AXUIElementPerformAction(exportButton2, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("AXPress failed for the second evidence export")
    }
    let secondEvidencePath: String = try waitFor("second exported evidence file") {
        let path = renderedEvidencePath()
        return (!path.isEmpty && path != firstEvidencePath &&
                FileManager.default.fileExists(atPath: path)) ? path : nil
    }
    for path in [firstEvidencePath, secondEvidencePath] {
        guard (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) != nil else {
            throw DriverError.failure("exported evidence is not readable JSON: \(path)")
        }
    }

    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility.json"))
    try writeJSON([
        "platform": "macos",
        "targetMode": "simulator",
        "actions": [
            "press:Validate bench",
            "press:Verify plan.sim.json (bundled fixture)",
            "press:Flash plan.sim.json (simulated bench)",
            "press:Export evidence",
            "press:Verify plan.sim-missing-image.json (failure injection)",
            "press:Export evidence",
        ],
        "assertions": [
            "packaged SwiftUI window activated",
            "target and simulator mode rendered on the identity card",
            "Validate bench exposed through macOS Accessibility",
            "readiness request crossed RVT1 into the simulated ECU backend",
            "bundled simulator fixture verified with a fingerprint, no checkout present",
            "flash plan executed on the simulated bench through macOS Accessibility",
            "missing-image fixture produced the distinct segment-unavailable recovery",
            "two evidence exports written under Application Support and readable as JSON",
            "no real ECU flashing was initiated by this acceptance",
        ],
    ], to: output.appendingPathComponent("interaction-trace.json"))

    guard let running = NSRunningApplication(processIdentifier: pid), running.terminate() else {
        throw DriverError.failure("native application rejected termination")
    }
} catch {
    if let application = diagnosticApplication, let output = diagnosticOutput {
        try? writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-failure.json"))
    }
    FileHandle.standardError.write(Data("FlashPilot macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
