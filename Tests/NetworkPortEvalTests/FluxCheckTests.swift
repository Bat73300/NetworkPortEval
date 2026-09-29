import XCTest
import Network
import PDFKit
@testable import NetworkPortEval
final class NetworkPortEvalTests: XCTestCase {
    func testSavedReportReloadsFromDiskWithCurrentAndLegacyDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_790_601_072)
        let report = SavedReport(id: UUID(), name: "Persisted UDP report", createdAt: date,
                                 flows: [Flow(name: "DNS", host: "1.1.1.1", port: 53, proto: "UDP")])
        for encoder in [JSONEncoder.pretty, JSONEncoder()] {
            let file = directory.appendingPathComponent("report.json")
            try AppDataStore.writePrivate(encoder.encode(report), to: file)
            let restored = try AppDataStore.decoder.decode(SavedReport.self, from: Data(contentsOf: file))
            XCTAssertEqual(restored.id, report.id)
            XCTAssertEqual(restored.createdAt, date)
            XCTAssertEqual(restored.flows, report.flows)
        }
    }

    func testStoredScheduleISODateReloads() throws {
        let date = Date(timeIntervalSince1970: 1_790_601_072)
        let schedule = ScheduledTest(templateID: UUID(), intervalCount: 1, intervalUnit: .hours, nextRunAt: date)
        let restored = try AppDataStore.decoder.decode(ScheduledTest.self, from: JSONEncoder.pretty.encode(schedule))
        XCTAssertEqual(restored.nextRunAt, date)
        XCTAssertThrowsError(try AppDataStore.decoder.decode(Date.self, from: Data("\"invalid-date\"".utf8)))
    }

    func testReportCSVImportPreservesAttemptsAndProvenance() throws {
        let date = Date(timeIntervalSince1970: 1790601072)
        var flow = Flow(name: "DNS", host: "1.1.1.1", port: 53, proto: "UDP")
        flow.attempts = [
            ProbeAttempt(number: 1, status: "Inconclusive", detail: "Silence", milliseconds: nil, testedAt: "2026-09-28T13:11:10Z"),
            ProbeAttempt(number: 2, status: "Open", detail: "Reply", milliseconds: 22, testedAt: "2026-09-28T13:11:12Z")
        ]
        let id = UUID()
        let csv = CSV.export([flow], reportName: "Remote report", createdAt: date, translate: Language.fr.text, reportID: id)
        let imported = try ReportCSVImport.parse(Data(csv.utf8), filename: "remote.csv", computer: "Remote Mac")
        XCTAssertEqual(imported.flows.count, 1)
        XCTAssertEqual(imported.flows[0].attempts.count, 2)
        XCTAssertEqual(imported.flows[0].status, "Open")
        XCTAssertFalse(imported.flows[0].selected)
        XCTAssertEqual(imported.createdAt, date)
        let restored = try AppDataStore.decoder.decode(SavedReport.self, from: JSONEncoder.pretty.encode(imported))
        XCTAssertEqual(restored.imported?.computer, "Remote Mac")
        XCTAssertTrue(ReportCSVImport.isDuplicate(imported, in: [restored]))
        XCTAssertThrowsError(try ReportCSVImport.parse(Data(CSV.blankTemplateCSV().utf8), filename: "template.csv"))
        XCTAssertThrowsError(try ReportCSVImport.parse(Data(csv.replacingOccurrences(of: "\"22\"", with: "\"-22\"").utf8), filename: "bad.csv"))
    }

    func testBlankTemplatePersistsWithoutSeedingDefaultFlows() throws {
        let existing = FlowTemplate(name: "Existing", flows: [Flow(name: "Original", host: "example.com", port: 443, proto: "TCP")])
        let blank = try BlankTemplate.make(name: "  Empty model  ", existing: [existing])
        XCTAssertEqual(blank.name, "Empty model")
        XCTAssertTrue(blank.flows.isEmpty)
        let loaded = TemplateBootstrap.load(try JSONEncoder.pretty.encode([existing, blank]))
        XCTAssertFalse(loaded.seededDefaults)
        XCTAssertEqual(loaded.templates[0], existing)
        XCTAssertTrue(loaded.templates[1].flows.isEmpty)
        var edited = loaded.templates[1]
        edited.flows.append(try FlowInputValidator.normalize(Flow(name: "Manual", host: "1.1.1.1", port: 53, proto: "UDP")))
        let restored = TemplateBootstrap.load(try JSONEncoder.pretty.encode([existing, edited]))
        XCTAssertEqual(restored.templates[1].flows.count, 1)
        XCTAssertThrowsError(try BlankTemplate.make(name: " ", existing: []))
        XCTAssertThrowsError(try BlankTemplate.make(name: "existing", existing: [existing]))
    }

    @MainActor func testDisabledScheduleSurvivesModelRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Model(storageDirectory: directory)
        let schedule = ScheduledTest(templateID: first.templates[0].id, intervalCount: 1, intervalUnit: .hours, nextRunAt: Date().addingTimeInterval(3600))
        first.scheduledTests = [schedule]
        first.setScheduledTestEnabled(schedule.id, false)
        let restarted = Model(storageDirectory: directory)
        XCTAssertEqual(restarted.scheduledTests.count, 1)
        XCTAssertEqual(restarted.scheduledTests.first?.id, schedule.id)
        XCTAssertEqual(restarted.scheduledTests.first?.isEnabled, false)
        XCTAssertNil(restarted.nextScheduledRun)
        XCTAssertFalse(restarted.hasScheduledProgram)
        let secondRestart = Model(storageDirectory: directory)
        XCTAssertEqual(secondRestart.scheduledTests.first?.isEnabled, false)
    }

    func testCSV() throws {
        let flows = try CSV.parse("\u{FEFF}name;url;port;protocol\r\n\"A; \"\"quoted\"\"\";https://example.com/path;443;tcp\r\nIPv6;[::1];53;UDP")
        XCTAssertEqual(flows.count, 2); XCTAssertEqual(flows[0].name, "A; \"quoted\""); XCTAssertEqual(flows[0].host, "example.com"); XCTAssertEqual(flows[1].host, "::1")
        let selectedColumn = try CSV.parse("host,port,selected\na.example,443,true\nb.example,443,false")
        XCTAssertEqual(selectedColumn.count, 2)
        XCTAssertTrue(selectedColumn.allSatisfy { !$0.selected }, "CSV selection flags must never implicitly enable imported network checks")
        XCTAssertThrowsError(try CSV.parse("host,port\nx,0")); XCTAssertThrowsError(try CSV.parse("host,port,protocol\nx,53,QUIC"))
        XCTAssertThrowsError(try CSV.parse("host,port,payload_hex\nx,53,XYZ"))
        XCTAssertThrowsError(try CSV.parse("host,port\n\"x,53"))
        XCTAssertEqual(try CSV.parse(CSV.templateCSV(flows)).count, 2)
        XCTAssertTrue(CSV.templateCSV(flows).contains(";"))
        XCTAssertTrue(CSV.export([Flow(name: "=1+1", host: "localhost", port: 80, proto: "TCP")]).contains("'=1+1"))
        XCTAssertEqual(Language.fr.text("Open"), "Ouvert"); XCTAssertEqual(Language.en.text("Open"), "Open")
        for language in Language.allCases where language != .en {
            XCTAssertNotEqual(language.text("Public Internet diagnostics (app-added)"), "Public Internet diagnostics (app-added)")
            XCTAssertNotEqual(language.text("These checks are separate from the network flows selected in Templates."), "These checks are separate from the network flows selected in Templates.")
            XCTAssertNotEqual(language.text("Show full details"), "Show full details")
            XCTAssertNotEqual(language.text("Show compact results"), "Show compact results")
            XCTAssertNotEqual(language.text("Review report before sharing"), "Review report before sharing")
            XCTAssertNotEqual(language.text("The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending."), "The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending.")
        }
    }
    func testScheduledPublicInternetCheckSettingAndLegacyDecode() throws {
        let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","templateID":"00000000-0000-0000-0000-000000000002","intervalCount":1,"intervalUnit":"Hours","isEnabled":true,"nextRunAt":0}"#.utf8)
        let legacy = try JSONDecoder().decode(ScheduledTest.self, from: legacyJSON)
        XCTAssertNil(legacy.includeInternetChecks, "Schedules saved before this choice should decode without migration failure")
        XCTAssertTrue(legacy.includeInternetChecks ?? true, "Legacy schedules retain the previous public-check behavior")

        let optedOut = ScheduledTest(templateID: UUID(), intervalCount: 1, intervalUnit: .hours, nextRunAt: Date(), includeInternetChecks: false)
        let decoded = try JSONDecoder().decode(ScheduledTest.self, from: JSONEncoder().encode(optedOut))
        XCTAssertEqual(decoded.includeInternetChecks, false)
        for language in Language.allCases where language != .en {
            XCTAssertNotEqual(language.text("Include public Internet checks"), "Include public Internet checks")
            XCTAssertNotEqual(language.text("Public checks on"), "Public checks on")
            XCTAssertNotEqual(language.text("Public checks off"), "Public checks off")
        }
    }
    func testFreshInstallSeedsPublicChecksWithoutReplacingSavedTemplates() throws {
        for data in [nil, Data("[]".utf8), Data("invalid".utf8)] {
            let result = TemplateBootstrap.load(data)
            XCTAssertTrue(result.seededDefaults)
            XCTAssertEqual(result.templates.count, 1)
            XCTAssertEqual(result.templates[0].name, "Public network checks")
            XCTAssertEqual(result.templates[0].flows.map(\.host), ["www.google.com", "www.apple.com", "www.cloudflare.com", "github.com", "www.wikipedia.org"])
            XCTAssertTrue(result.templates[0].flows.allSatisfy(\.selected))
        }

        let intentionallyEmpty = FlowTemplate(name: "My empty template", flows: [])
        let existingData = try JSONEncoder().encode([intentionallyEmpty])
        let existing = TemplateBootstrap.load(existingData)
        XCTAssertFalse(existing.seededDefaults)
        XCTAssertEqual(existing.templates, [intentionallyEmpty])
    }
    func testRunSafetyWarningThresholdAndAttemptEstimate() {
        XCTAssertFalse(RunSafetyPolicy.shouldWarn(selectedFlowCount: 99))
        XCTAssertTrue(RunSafetyPolicy.shouldWarn(selectedFlowCount: 100))
        XCTAssertTrue(RunSafetyPolicy.shouldWarn(selectedFlowCount: 101))
        XCTAssertEqual(RunSafetyPolicy.maximumPossibleAttempts(selectedFlowCount: 0, retriesAfterFailure: 3), 0)
        XCTAssertEqual(RunSafetyPolicy.maximumPossibleAttempts(selectedFlowCount: 2, retriesAfterFailure: 0), 2)
        XCTAssertEqual(RunSafetyPolicy.maximumPossibleAttempts(selectedFlowCount: 2, retriesAfterFailure: 3), 8)
        XCTAssertEqual(RunSafetyPolicy.maximumPossibleAttempts(selectedFlowCount: -1, retriesAfterFailure: -3), 0)
    }
    func testTCPAndUDP() throws {
        for proto in ["TCP", "UDP"] {
            let listener = try NWListener(using: proto == "TCP" ? .tcp : .udp, on: .any)
            let ready = expectation(description: "listener ready")
            let queue = DispatchQueue(label: "test.listener")
            var connections: [NWConnection] = []
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { connection in
                connections.append(connection); connection.start(queue: queue)
                if proto == "UDP" { connection.receiveMessage { data, _, _, _ in connection.send(content: data, completion: .contentProcessed { _ in }) } }
            }
            listener.start(queue: queue); wait(for: [ready], timeout: 3)
            let done = expectation(description: proto)
            let probe = Probe()
            probe.run(Flow(name: "", host: "127.0.0.1", port: listener.port!.rawValue, proto: proto), timeout: 2) { result in XCTAssertEqual(result.status, "Open"); XCTAssertNotNil(result.milliseconds); done.fulfill() }
            wait(for: [done], timeout: 4); listener.cancel(); connections.forEach { $0.cancel() }
        }
    }
    func testUDPSilenceAndCancellation() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let ready = expectation(description: "ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        var retained: [NWConnection] = []
        listener.newConnectionHandler = { retained.append($0); $0.start(queue: .global()) }
        listener.start(queue: .global()); wait(for: [ready], timeout: 3)
        let done = expectation(description: "silence")
        let probe = Probe(); probe.run(Flow(name: "", host: "127.0.0.1", port: listener.port!.rawValue, proto: "UDP"), timeout: 0.2) { result in XCTAssertEqual(result.status, "Inconclusive"); done.fulfill() }
        wait(for: [done], timeout: 2)
        let cancelled = expectation(description: "cancel")
        let second = Probe(); second.run(Flow(name: "", host: "127.0.0.1", port: listener.port!.rawValue, proto: "UDP"), timeout: 5) { result in XCTAssertEqual(result.status, "Cancelled"); cancelled.fulfill() }; second.cancel()
        wait(for: [cancelled], timeout: 2); listener.cancel(); retained.forEach { $0.cancel() }
    }

    func testBrandedPDFExportUsesA4AndContinuesAcrossPages() throws {
        let flows = (0..<48).map { index -> Flow in
            var flow = Flow(name: "Public service \(index + 1)", host: "service\(index + 1).example.com", port: 443, proto: "HTTPS", category: "General")
            flow.status = index.isMultiple(of: 3) ? "Error" : "Open"
            flow.detail = index.isMultiple(of: 3) ? "Connection timed out after retrying." : "TLS connection established successfully."
            flow.milliseconds = index.isMultiple(of: 3) ? nil : 42
            return flow
        }
        let report = SavedReport(id: UUID(), name: "PDF export verification", createdAt: Date(), flows: flows, publicIP: "203.0.113.10", internetStatus: "Internet available")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkPortEval-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFReport.write(report, to: url, translate: Language.en.text)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 595, accuracy: 1)
        XCTAssertEqual(bounds.height, 842, accuracy: 1)
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("Created with NetworkPortEval"))
        XCTAssertTrue(text.contains("PDF export verification"))
        XCTAssertTrue(text.contains("Saved reports are stored locally and are not encrypted by the app."))
        for index in 1...48 {
            XCTAssertTrue(text.contains("Public service \(index)"), "PDF must retain every report row across page breaks")
            XCTAssertTrue(text.contains("service\(index).example.com"), "PDF must retain every destination across page breaks")
        }

        let localizedURL = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkPortEval-\(UUID().uuidString)-fr.pdf")
        defer { try? FileManager.default.removeItem(at: localizedURL) }
        try PDFReport.write(report, to: localizedURL, locale: Locale(identifier: "fr_FR"), translate: Language.fr.text)
        let localizedText = try XCTUnwrap(PDFDocument(url: localizedURL)?.string)
        XCTAssertTrue(localizedText.contains("Créé avec NetworkPortEval"))
        XCTAssertTrue(localizedText.contains("Une vision claire de la connectivité réseau de votre Mac."))
        XCTAssertTrue(localizedText.contains("Les rapports enregistrés restent en local et ne sont pas chiffrés par l’application."))
    }
}
