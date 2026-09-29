import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreText

struct SavedReport: Identifiable, Codable {
    var id: UUID; var name: String; var createdAt: Date; var flows: [Flow]
    var imported: ImportedReportOrigin? = nil
    var folderID: UUID? = nil
    var publicIP: String? = nil
    var internetStatus: String? = nil
    var internetChecks: [InternetCheck]? = nil
    var failures: Int { flows.filter { ["Closed", "Error", "Inconclusive"].contains($0.status) }.count }
}
struct ReportFolder: Identifiable, Codable, Hashable { var id = UUID(); var name: String }
struct ScheduledTest: Identifiable, Codable, Hashable {
    var id: UUID
    var templateID: UUID
    var intervalCount: Int
    var intervalUnit: ScheduleUnit
    var isEnabled: Bool
    var nextRunAt: Date
    var lastRunAt: Date? = nil
    var lastReportID: UUID? = nil
    // Optional to preserve decoding of schedules saved before this setting existed.
    // Legacy schedules keep their prior behavior: public checks enabled.
    var includeInternetChecks: Bool? = nil
    init(id: UUID = UUID(), templateID: UUID, intervalCount: Int, intervalUnit: ScheduleUnit, isEnabled: Bool = true, nextRunAt: Date, lastRunAt: Date? = nil, lastReportID: UUID? = nil, includeInternetChecks: Bool? = nil) {
        self.id = id; self.templateID = templateID; self.intervalCount = ScheduleUnit.normalizedCount(intervalCount)
        self.intervalUnit = intervalUnit; self.isEnabled = isEnabled; self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt; self.lastReportID = lastReportID
        self.includeInternetChecks = includeInternetChecks
    }
}
enum Screen: Hashable { case templates, schedules, overview, results, history }
enum ExportFormat: String, CaseIterable, Identifiable { case csv = "CSV", txt = "TXT", pdf = "PDF", json = "JSON"; var id: String { rawValue } }
private struct SettingsSnapshot: Codable {
    var retryCount: Int
    var retryDelay: Double
    var testInterval: Double
    var languageCode: String
    var reportsFolder: String
    var lastTemplate: String?
    var lastExportFolder: String? = nil
    var scheduleEnabled: Bool? = nil
    var scheduleCount: Int? = nil
    var scheduleUnit: String? = nil
    var scheduleTemplate: String? = nil
    var scheduledTests: [ScheduledTest]? = nil
}

@MainActor final class Model: ObservableObject {
    private var restoringSettings = true
    private var storageDirectory: URL? = nil
    @Published var templates: [FlowTemplate] = []
    @Published var selectedTemplateID: UUID?
    @Published var reports: [SavedReport] = []
    @Published var reportFolders: [ReportFolder] = []
    @Published var emailRecipients: [EmailRecipient] = []
    @Published var emailRecipientSelection: Set<UUID> = []
    @Published var showingEmailRecipients = false
    @Published var selectedReportID: UUID?
    @Published var selectedReportFolderID: UUID?
    @Published var selectedReportIDs: Set<UUID> = []
    @Published var showingBulkDeleteConfirmation = false
    @Published var showingHelp = false
    @Published var screen: Screen = .templates
    @Published var flows: [Flow] = []
    @Published var collapsedCategories: Set<String> = []
    @Published var running = false
    @Published var finalizing = false
    @Published var messageTitle = "Error"
    @Published var message: String? { didSet { if message == nil { messageTitle = "Error" } } }
    @Published var completed = 0
    @Published var timeout = 5.0
    @Published var retryCount = UserDefaults.standard.object(forKey: "retryCount") == nil ? 3 : UserDefaults.standard.integer(forKey: "retryCount") { didSet { UserDefaults.standard.set(retryCount, forKey: "retryCount"); saveSettingsSnapshot() } }
    @Published var retryDelay = UserDefaults.standard.object(forKey: "retryDelay") == nil ? 1.0 : UserDefaults.standard.double(forKey: "retryDelay") { didSet { UserDefaults.standard.set(retryDelay, forKey: "retryDelay"); saveSettingsSnapshot() } }
    @Published var testInterval = max(0.5, UserDefaults.standard.object(forKey: "testInterval") == nil ? 1.0 : UserDefaults.standard.double(forKey: "testInterval")) { didSet { UserDefaults.standard.set(max(0.5, testInterval), forKey: "testInterval"); saveSettingsSnapshot() } }
    @Published var filterStatus = "All"
    @Published var compactResults = true
    @Published var reportFolder: URL { didSet { saveSettingsSnapshot() } }
    @Published var lastExportFolder: URL? = UserDefaults.standard.string(forKey: "lastExportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    @Published var scheduledTests: [ScheduledTest] = [] { didSet { saveSettingsSnapshot(); rescheduleAutomaticRuns() } }
    @Published var showingScheduleEditor = false
    @Published var editingScheduledTestID: UUID?
    @Published var scheduleTemplateDraft: UUID?
    @Published var scheduleCountDraft = 1
    @Published var scheduleUnitDraft: ScheduleUnit = .hours
    @Published var scheduleIncludesInternetChecks = true
    @Published var scheduleDeleteTarget: ScheduledTest?
    @Published var showingInternetChoice = false
    @Published var exportName = "Network report"
    @Published var exportFormat = ExportFormat.csv
    @Published var showExport = false
    @Published var showRename = false
    @Published var renameReportPrompt = false
    @Published var templateNamePrompt = false
    @Published var newTemplatePrompt = false
    @Published var newTemplateName = ""
    @Published var templateDeleteTarget: FlowTemplate?
    @Published var showingCategoryManager = false
    @Published var showingFlowEditor = false
    @Published var editingFlowID: UUID?
    @Published var categoryNameDraft = ""
    @Published var categoryEditingDraft: String?
    @Published var flowDeleteTarget: UUID?
    @Published var categoryNewName = ""
    @Published var categoryRenameName = ""
    @Published var categoryRenameTarget: String?
    @Published var categoryDeleteTarget: String?
    @Published var flowEditorName = ""
    @Published var flowEditorHost = ""
    @Published var flowEditorPort = "443"
    @Published var flowEditorProtocol = "TCP"
    @Published var flowEditorCategory = "General"
    @Published var flowEditorPayload = ""
    @Published var flowEditorComment = ""
    @Published var deleteTarget: SavedReport?
    @Published var reportFolderDeleteTarget: ReportFolder?
    @Published var showingNewReportFolder = false
    @Published var showingRenameReportFolder = false
    @Published var reportFolderNameDraft = ""
    @Published var reportFolderRenameID: UUID?
    @Published var draftName = ""
    @Published var languageCode = UserDefaults.standard.string(forKey: "language") ?? "en" { didSet { UserDefaults.standard.set(languageCode, forKey: "language"); saveSettingsSnapshot() } }
    private var probes: [UUID: Probe] = [:]; private var next = 0; private var retryQueue: [Int] = []; private var generation = UUID()
    private var nextLaunchAt = Date.distantPast
    private var launchScheduled = false
    private var internetTask: Task<InternetDiagnostics, Never>?
    private var scheduledRunTask: Task<Void, Never>?
    private var activeScheduledTestID: UUID?
    private var pendingScheduledTestID: UUID?
    private var screenBeforeScheduledRun: Screen = .schedules
    var language: Language { Language(rawValue: languageCode) ?? .en }
    var selectedReport: SavedReport? { reports.first { $0.id == selectedReportID } }
    var sortedReportFolders: [ReportFolder] { reportFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var visibleReports: [SavedReport] { reports.filter { selectedReportFolderID == nil || $0.folderID == selectedReportFolderID }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt } }
    var visibleReportSelection: Bool? { VisibleItemSelection.state(visibleIDs: Set(visibleReports.map(\.id)), selectedIDs: selectedReportIDs) }
    var visibleSelectedReportCount: Int { VisibleItemSelection.selectedVisibleIDs(visibleIDs: Set(visibleReports.map(\.id)), selectedIDs: selectedReportIDs).count }
    var selectedTemplate: FlowTemplate? { templates.first { $0.id == selectedTemplateID } }
    var selectedFlowCount: Int { flows.filter(\.selected).count }
    var scheduleTemplateSelectedFlowCount: Int {
        guard let id = scheduleTemplateDraft, let template = templates.first(where: { $0.id == id }) else { return 0 }
        return template.flows.filter(\.selected).count
    }
    func largeRunWarning(for count: Int) -> String? {
        guard RunSafetyPolicy.shouldWarn(selectedFlowCount: count) else { return nil }
        return String(format: t("Large selection: %d tests. Large or repeated runs can trigger network rate limits or security blocks. Run only approved destinations; consider a smaller selection."), count)
    }
    var selectedDestinationDisclosure: String {
        let selected = flows.filter(\.selected)
        var lines = selected.prefix(6).map { "• \($0.host):\($0.port) · \($0.proto)" }
        if selected.count > 6 { lines.append("… + \(selected.count - 6)") }
        let maximumAttempts = RunSafetyPolicy.maximumPossibleAttempts(selectedFlowCount: selected.count, retriesAfterFailure: retryCount)
        let countSummary = String(format: t("Selected tests: %d · up to %d attempts"), selected.count, maximumAttempts)
        return "\(t("Selected network destinations and protocols:"))\n\(countSummary)\n\(lines.joined(separator: "\n"))"
    }
    var nextScheduledRun: Date? { scheduledTests.filter { schedule in schedule.isEnabled && templates.contains(where: { $0.id == schedule.templateID }) }.map(\.nextRunAt).min() }
    var hasScheduledProgram: Bool { scheduledTests.contains { schedule in schedule.isEnabled && templates.contains(where: { $0.id == schedule.templateID }) } }
    var scheduleTemplateHasSelectedFlows: Bool { scheduleTemplateDraft.flatMap { id in templates.first(where: { $0.id == id }) }?.flows.contains(where: \.selected) == true }
    var currentCategories: [String] { selectedTemplate?.categories ?? ["General"] }
    var storageBase: URL { storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NetworkPortEval", isDirectory: true) }
    var settingsFolder: URL { storageBase.appendingPathComponent("Settings", isDirectory: true) }
    var templatesFolder: URL { storageBase.appendingPathComponent("Templates", isDirectory: true) }
    var defaultReportsFolder: URL { storageBase.appendingPathComponent("Reports", isDirectory: true) }
    var emailRecipientsFile: URL { settingsFolder.appendingPathComponent("email-recipients.json") }
    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if storageDirectory == nil {
            TemporaryReportEmailFiles.cleanupStaleDirectories()
            Self.migrateLegacyStorageIfNeeded()
            Self.restoreSettingsFromSnapshotIfNeeded()
        }
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NetworkPortEval/Reports", isDirectory: true)
        let savedPath = UserDefaults.standard.string(forKey: "reportsFolder")
        reportFolder = storageDirectory?.appendingPathComponent("Reports", isDirectory: true) ?? savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standard
        retryCount = UserDefaults.standard.object(forKey: "retryCount") == nil ? 3 : UserDefaults.standard.integer(forKey: "retryCount")
        retryDelay = UserDefaults.standard.object(forKey: "retryDelay") == nil ? 1 : UserDefaults.standard.double(forKey: "retryDelay")
        testInterval = max(0.5, UserDefaults.standard.object(forKey: "testInterval") == nil ? 1 : UserDefaults.standard.double(forKey: "testInterval"))
        languageCode = UserDefaults.standard.string(forKey: "language") ?? "en"
        loadEmailRecipients(); loadTemplates(); loadReportFolders(); loadReports()
        let settingsFile = storageBase.appendingPathComponent("Settings/preferences.json")
        let savedSchedules = (try? Data(contentsOf: settingsFile)).flatMap { try? AppDataStore.decoder.decode(SettingsSnapshot.self, from: $0) }?.scheduledTests
        if let savedSchedules {
            scheduledTests = savedSchedules
        } else {
            let defaults = UserDefaults.standard
            let legacyEnabled = defaults.bool(forKey: "scheduleEnabled")
            let legacyTemplateID = defaults.string(forKey: "scheduleTemplate").flatMap(UUID.init(uuidString:)) ?? selectedTemplateID
            if legacyEnabled, let legacyTemplateID, templates.contains(where: { $0.id == legacyTemplateID }) {
                let count = ScheduleUnit.normalizedCount(defaults.object(forKey: "scheduleCount") == nil ? 1 : defaults.integer(forKey: "scheduleCount"))
                let unit = ScheduleUnit(rawValue: defaults.string(forKey: "scheduleUnit") ?? "Hours") ?? .hours
                scheduledTests = [ScheduledTest(templateID: legacyTemplateID, intervalCount: count, intervalUnit: unit, nextRunAt: Date().addingTimeInterval(ScheduleUnit.interval(count: count, unit: unit)))]
            }
        }
        if let template = selectedTemplate {
            flows = template.flows
            collapsedCategories = Set(UserDefaults.standard.stringArray(forKey: "collapsedCategories.\(template.id.uuidString)") ?? [])
        }
        if selectedTemplate == nil, let report = selectedReport, flows.isEmpty { flows = report.flows }
        restoringSettings = false
        saveSettingsSnapshot()
        rescheduleAutomaticRuns()
    }
    private static func migrateLegacyStorageIfNeeded() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("FluxCheck", isDirectory: true)
        let destination = support.appendingPathComponent("NetworkPortEval", isDirectory: true)
        do { try AppDataStore.copyMissingItems(from: legacy, to: destination, fileManager: fm) }
        catch { NSLog("NetworkPortEval could not copy previous FluxCheck data: %@", error.localizedDescription) }
        let oldTemplate = destination.appendingPathComponent("templates.json")
        let newTemplate = destination.appendingPathComponent("Templates/templates.json")
        if fm.fileExists(atPath: oldTemplate.path), !fm.fileExists(atPath: newTemplate.path) {
            do { try fm.createDirectory(at: newTemplate.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.copyItem(at: oldTemplate, to: newTemplate) }
            catch { NSLog("NetworkPortEval could not migrate the template file: %@", error.localizedDescription) }
        }
        if let oldReportsPath = UserDefaults.standard.string(forKey: "reportsFolder"), oldReportsPath == legacy.path || oldReportsPath.hasPrefix(legacy.path + "/") {
            let suffix = String(oldReportsPath.dropFirst(legacy.path.count))
            let migratedPath = destination.path + suffix
            if fm.fileExists(atPath: migratedPath) { UserDefaults.standard.set(migratedPath, forKey: "reportsFolder") }
        }
    }
    private static func restoreSettingsFromSnapshotIfNeeded() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("NetworkPortEval/Settings", isDirectory: true)
        let file = folder.appendingPathComponent("preferences.json")
        try? AppDataStore.restrictPermissions(at: file)
        guard let data = try? Data(contentsOf: file), let snapshot = try? AppDataStore.decoder.decode(SettingsSnapshot.self, from: data) else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "retryCount") == nil { defaults.set(snapshot.retryCount, forKey: "retryCount") }
        if defaults.object(forKey: "retryDelay") == nil { defaults.set(snapshot.retryDelay, forKey: "retryDelay") }
        if defaults.object(forKey: "testInterval") == nil { defaults.set(max(0.5, snapshot.testInterval), forKey: "testInterval") }
        if defaults.string(forKey: "language") == nil { defaults.set(snapshot.languageCode, forKey: "language") }
        if defaults.string(forKey: "reportsFolder") == nil { defaults.set(snapshot.reportsFolder, forKey: "reportsFolder") }
        if defaults.string(forKey: "lastTemplate") == nil, let lastTemplate = snapshot.lastTemplate { defaults.set(lastTemplate, forKey: "lastTemplate") }
        if defaults.string(forKey: "lastExportFolder") == nil, let folder = snapshot.lastExportFolder { defaults.set(folder, forKey: "lastExportFolder") }
        if defaults.object(forKey: "scheduleEnabled") == nil, let value = snapshot.scheduleEnabled { defaults.set(value, forKey: "scheduleEnabled") }
        if defaults.object(forKey: "scheduleCount") == nil, let value = snapshot.scheduleCount { defaults.set(value, forKey: "scheduleCount") }
        if defaults.string(forKey: "scheduleUnit") == nil, let value = snapshot.scheduleUnit { defaults.set(value, forKey: "scheduleUnit") }
        if defaults.string(forKey: "scheduleTemplate") == nil, let value = snapshot.scheduleTemplate { defaults.set(value, forKey: "scheduleTemplate") }
    }
    private func saveSettingsSnapshot() {
        guard !restoringSettings else { return }
        let defaults = UserDefaults.standard
        let legacy = scheduledTests.first(where: \.isEnabled) ?? scheduledTests.first
        let snapshot = SettingsSnapshot(retryCount: retryCount, retryDelay: retryDelay, testInterval: testInterval, languageCode: languageCode, reportsFolder: reportFolder.path, lastTemplate: defaults.string(forKey: "lastTemplate"), lastExportFolder: lastExportFolder?.path, scheduleEnabled: scheduledTests.contains(where: \.isEnabled), scheduleCount: legacy?.intervalCount, scheduleUnit: legacy?.intervalUnit.rawValue, scheduleTemplate: legacy?.templateID.uuidString, scheduledTests: scheduledTests)
        do {
            try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(snapshot), to: settingsFolder.appendingPathComponent("preferences.json"))
        } catch { NSLog("NetworkPortEval could not save settings snapshot: %@", error.localizedDescription) }
    }
    func t(_ value: String) -> String { language.text(value) }
    func loadEmailRecipients() {
        try? AppDataStore.restrictPermissions(at: emailRecipientsFile)
        guard let data = try? Data(contentsOf: emailRecipientsFile),
              let decoded = try? AppDataStore.decoder.decode([EmailRecipient].self, from: data) else { return }
        emailRecipients = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @discardableResult func saveEmailRecipient(_ recipient: EmailRecipient) -> Bool {
        let normalized = EmailRecipient(id: recipient.id, name: recipient.name, emailAddress: recipient.emailAddress, comment: recipient.comment)
        guard EmailRecipient.isValidAddress(normalized.emailAddress) else { message = "Enter a valid email address."; return false }
        guard !emailRecipients.contains(where: { $0.id != normalized.id && $0.emailAddress.caseInsensitiveCompare(normalized.emailAddress) == .orderedSame }) else {
            message = "A recipient with this email address already exists."; return false
        }
        var updated = emailRecipients
        if let index = updated.firstIndex(where: { $0.id == normalized.id }) { updated[index] = normalized }
        else { updated.append(normalized) }
        updated.sort { ($0.name.isEmpty ? $0.emailAddress : $0.name).localizedCaseInsensitiveCompare($1.name.isEmpty ? $1.emailAddress : $1.name) == .orderedAscending }
        do {
            try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(updated), to: emailRecipientsFile)
            emailRecipients = updated
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func deleteEmailRecipient(_ id: UUID) {
        var updated = emailRecipients
        updated.removeAll { $0.id == id }
        do {
            try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(updated), to: emailRecipientsFile)
            emailRecipients = updated
            emailRecipientSelection.remove(id)
        } catch { message = error.localizedDescription }
    }
    func beginEmailReport() {
        guard selectedReport != nil else { return }
        message = nil
        emailRecipientSelection = []
        showingEmailRecipients = true
    }
    func toggleEmailRecipient(_ id: UUID, selected: Bool) {
        if selected { emailRecipientSelection.insert(id) } else { emailRecipientSelection.remove(id) }
    }
    @discardableResult func emailSelectedReport() -> Bool {
        guard let report = selectedReport else { return false }
        let recipients = emailRecipients.filter { emailRecipientSelection.contains($0.id) }
        guard !recipients.isEmpty else { message = "Select at least one recipient."; return false }
        let service = NSSharingService(named: .composeEmail)
        guard let service else { message = "No email service is available. Export the CSV and attach it manually."; return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkPortEval-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let csvURL = folder.appendingPathComponent("NetworkPortEval-results.csv")
            let pdfURL = folder.appendingPathComponent("NetworkPortEval-results.pdf")
            try reportCSV(report).write(to: csvURL, atomically: true, encoding: .utf8)
            try PDFReport.write(report, to: pdfURL, locale: .current, translate: t)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: csvURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pdfURL.path)
            let body = "Ce message contient des rapports de test réseau effectués avec NetworkPortEval.\n\nLes fichiers CSV et PDF joints présentent les résultats du test. Vérifiez qu’ils ne contiennent pas d’informations sensibles avant de les partager.\n\nNetworkPortEval : https://github.com/Bat73300/NetworkPortEval\nLien App Store : à venir\n"
            let items: [Any] = [body as NSString, csvURL, pdfURL]
            guard service.canPerform(withItems: items) else {
                try? FileManager.default.removeItem(at: folder)
                message = "No email service is available. Export the CSV and attach it manually."
                return false
            }
            service.delegate = TemporaryReportEmailDelegate.shared
            service.recipients = recipients.map(\.emailAddress)
            service.subject = "NetworkPortEval — " + t("Test results")
            service.perform(withItems: items)
            return true
        } catch {
            try? FileManager.default.removeItem(at: folder)
            message = error.localizedDescription
            return false
        }
    }
    func loadTemplates() {
        do {
            try FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
            let url = templatesFolder.appendingPathComponent("templates.json")
            try? AppDataStore.restrictPermissions(at: url)
            let loaded = TemplateBootstrap.load(try? Data(contentsOf: url))
            templates = loaded.templates
            if loaded.seededDefaults { saveTemplates() }
            let lastID = UserDefaults.standard.string(forKey: "lastTemplate").flatMap(UUID.init(uuidString:))
            selectedTemplateID = templates.first(where: { $0.id == lastID })?.id ?? templates.first?.id
        } catch { message = error.localizedDescription }
    }
    func saveTemplates() {
        do { try FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true); try AppDataStore.writePrivate(JSONEncoder.pretty.encode(templates), to: templatesFolder.appendingPathComponent("templates.json")) }
        catch { message = error.localizedDescription }
    }
    private func syncCurrentTemplate() {
        guard let selectedTemplateID, let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) else { return }
        templates[index].flows = flows
        templates[index].categories = FlowCategories.merged(existing: templates[index].categories, flows: flows)
        saveTemplates()
    }
    func createCategory(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !currentCategories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        guard let selectedTemplateID, let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) else { return }
        templates[index].categories.append(name); templates[index].categories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }; saveTemplates()
    }
    func renameCategory(_ oldName: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldName != "General", !name.isEmpty, !currentCategories.contains(where: { $0 != oldName && $0.caseInsensitiveCompare(name) == .orderedSame }),
              let selectedTemplateID, let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) else { return }
        templates[index].categories = templates[index].categories.map { $0 == oldName ? name : $0 }
        templates[index].flows = templates[index].flows.map { flow in var flow = flow; if flow.category == oldName { flow.category = name }; return flow }
        templates[index].categories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        flows = templates[index].flows
        saveTemplates()
    }
    func removeCategory(_ name: String) {
        guard name != "General", let selectedTemplateID, let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) else { return }
        templates[index].categories.removeAll { $0 == name }
        templates[index].flows = templates[index].flows.map { flow in var flow = flow; if flow.category == name { flow.category = "General" }; return flow }
        flows = templates[index].flows; saveTemplates()
    }
    func addFlow(_ flow: Flow) {
        flows.append(flow); syncCurrentTemplate()
    }
    func updateFlow(_ flow: Flow) {
        guard let index = flows.firstIndex(where: { $0.id == flow.id }) else { return }
        flows[index] = flow; syncCurrentTemplate()
    }
    func removeFlow(_ id: UUID) {
        flows.removeAll { $0.id == id }; syncCurrentTemplate()
    }
    func beginAddFlow() {
        editingFlowID = nil; flowEditorName = ""; flowEditorHost = ""; flowEditorPort = "443"; flowEditorProtocol = "TCP"; flowEditorCategory = currentCategories.first ?? "General"; flowEditorPayload = ""; flowEditorComment = ""; showingFlowEditor = true
    }
    func beginEditFlow(_ id: UUID) {
        guard let flow = flows.first(where: { $0.id == id }) else { return }
        editingFlowID = id; flowEditorName = flow.name; flowEditorHost = flow.host; flowEditorPort = String(flow.port); flowEditorProtocol = flow.proto; flowEditorCategory = flow.category; flowEditorPayload = flow.payload; flowEditorComment = flow.comment; showingFlowEditor = true
    }
    @discardableResult func saveFlow(_ flow: Flow) -> Bool {
        let normalized: Flow
        do { normalized = try FlowInputValidator.normalize(flow) }
        catch { message = error.localizedDescription; return false }
        if flows.contains(where: { $0.id != normalized.id && CSV.destinationKey(host: $0.host, port: $0.port) == CSV.destinationKey(host: normalized.host, port: normalized.port) }) {
            message = t("A flow with this destination and port already exists in this template."); return false
        }
        if flows.contains(where: { $0.id == normalized.id }) { updateFlow(normalized) }
        else { addFlow(normalized) }
        return true
    }
    func selectTemplate(_ id: UUID?) {
        selectedTemplateID = id; guard let template = selectedTemplate else { return }
        UserDefaults.standard.set(template.id.uuidString, forKey: "lastTemplate"); saveSettingsSnapshot(); flows = template.flows; screen = .templates
        collapsedCategories = Set(UserDefaults.standard.stringArray(forKey: "collapsedCategories.\(template.id.uuidString)") ?? [])
    }
    func createTemplateFromCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url); guard data.count <= 5_000_000 else { throw CSV.error("Maximum: 5 MB per CSV.") }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw CSV.error("Save the CSV using UTF-8 encoding.") }
            let parsed = try CSV.parse(text); guard !parsed.isEmpty else { throw CSV.error("CSV is empty.") }
            let existingCategories = currentCategories
            let createdCategories = FlowCategories.additions(existing: existingCategories, flows: parsed)
            let canonicalCategories = existingCategories + createdCategories
            let normalizedParsed = parsed.map { flow -> Flow in
                var flow = flow
                flow.category = FlowCategories.canonicalName(for: flow.category, existing: canonicalCategories)
                return flow
            }
            var known = Set(flows.map { CSV.destinationKey(host: $0.host, port: $0.port) })
            var added: [Flow] = []; var duplicates: [String] = []
            for flow in normalizedParsed {
                let key = CSV.destinationKey(host: flow.host, port: flow.port)
                if known.insert(key).inserted { added.append(flow) }
                else { duplicates.append("\(flow.host):\(flow.port)") }
            }
            flows.append(contentsOf: added); syncCurrentTemplate()
            let addedText = "\(added.count) \(added.count == 1 ? t("new flow added") : t("new flows added"))"
            let categoriesText = createdCategories.isEmpty ? "" : " \(t("Categories created")): \(createdCategories.joined(separator: ", "))."
            messageTitle = "Import complete"
            if duplicates.isEmpty { message = "\(t("Import complete")): \(addedText).\(categoriesText)" }
            else { message = "\(t("Import complete")): \(addedText); \(duplicates.count) \(duplicates.count == 1 ? t("duplicate skipped") : t("duplicates skipped")). \(t("Already present")): \(CSVImportFeedback.duplicatePreview(duplicates)).\(categoriesText)" }
        } catch { message = error.localizedDescription }
    }
    func exportSelectedTemplateCSV() {
        guard let template = selectedTemplate else { return }
        let safeName = template.name.replacingOccurrences(of: "/", with: "-")
        saveTemplateCSV(CSV.templateCSV(template.flows), suggestedName: "\(safeName).csv")
    }
    func exportBlankTemplateCSV() {
        saveTemplateCSV(CSV.blankTemplateCSV(), suggestedName: "networkporteval-template-blank.csv")
    }
    func exportSampleTemplateCSV() {
        let sample = "name,comment,category,host,port,protocol,payload_hex\r\nHTTPS,Validate the server TLS certificate,Web,example.com,443,HTTPS,\r\nDNS,Check the DNS resolver,Infrastructure,1.1.1.1,53,UDP,123401000001000000000000076578616d706c6503636f6d0000010001\r\n"
        do { saveTemplateCSV(CSV.templateCSV(try CSV.parse(sample)), suggestedName: "networkporteval-template-sample.csv") }
        catch { message = error.localizedDescription }
    }
    private func saveTemplateCSV(_ text: String, suggestedName: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = suggestedName
        panel.directoryURL = lastExportFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); rememberExportLocation(url) }
        catch { message = error.localizedDescription }
    }
    var newTemplateError: String? {
        do { _ = try BlankTemplate.make(name: newTemplateName, existing: templates); return nil }
        catch { return t(error.localizedDescription) }
    }
    func createBlankTemplate() {
        guard !running, !finalizing else { return }
        do {
            let template = try BlankTemplate.make(name: newTemplateName, existing: templates)
            let updated = templates + [template]
            try FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(updated), to: templatesFolder.appendingPathComponent("templates.json"))
            templates = updated
            selectTemplate(template.id)
            selectedReportID = nil
            filterStatus = "All"
            completed = 0
            screen = .templates
            newTemplateName = ""
        } catch { message = error.localizedDescription }
    }
    func saveCurrentAsTemplate() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        templates.append(FlowTemplate(name: name, flows: flows)); saveTemplates(); selectTemplate(templates.last?.id); screen = .templates
    }
    func deleteTemplate(_ id: UUID) {
        guard !running, !finalizing, templates.count > 1,
              templates.contains(where: { $0.id == id }) else {
            if templates.count <= 1 { message = "At least one template must remain." }
            return
        }
        templates.removeAll { $0.id == id }
        scheduledTests.removeAll { $0.templateID == id }
        UserDefaults.standard.removeObject(forKey: "collapsedCategories.\(id.uuidString)")
        saveTemplates()
        if selectedTemplateID == id { selectTemplate(templates[0].id) }
        else { saveSettingsSnapshot() }
    }
    func setFlowSelection(_ id: UUID, _ selected: Bool) {
        if let index = flows.firstIndex(where: { $0.id == id }) { flows[index].selected = selected }
        syncCurrentTemplate()
    }
    func categorySelection(_ category: String) -> Bool? {
        let items = flows.filter { $0.category == category }
        guard !items.isEmpty else { return false }
        let selectedCount = items.filter(\.selected).count
        return selectedCount == 0 ? false : selectedCount == items.count ? true : nil
    }
    func setCategorySelection(_ category: String, _ selected: Bool) {
        guard !running, !finalizing else { return }
        for index in flows.indices where flows[index].category == category { flows[index].selected = selected }
        syncCurrentTemplate()
    }
    var allCategoriesSelection: Bool? {
        let items = flows
        guard !items.isEmpty else { return false }
        let selectedCount = items.filter(\.selected).count
        return selectedCount == 0 ? false : selectedCount == items.count ? true : nil
    }
    func setAllCategorySelection(_ selected: Bool) {
        guard !running, !finalizing else { return }
        for index in flows.indices { flows[index].selected = selected }
        syncCurrentTemplate()
    }
    func isCategoryCollapsed(_ category: String) -> Bool { collapsedCategories.contains(category) }
    func toggleCategoryCollapsed(_ category: String) {
        if collapsedCategories.contains(category) { collapsedCategories.remove(category) }
        else { collapsedCategories.insert(category) }
        if let templateID = selectedTemplateID {
            UserDefaults.standard.set(Array(collapsedCategories), forKey: "collapsedCategories.\(templateID.uuidString)")
        }
    }
    func beginAddScheduledTest() {
        editingScheduledTestID = nil
        scheduleTemplateDraft = selectedTemplateID ?? templates.first?.id
        scheduleCountDraft = 1
        scheduleUnitDraft = .hours
        scheduleIncludesInternetChecks = true
        showingScheduleEditor = true
    }
    func beginEditScheduledTest(_ scheduledTest: ScheduledTest) {
        editingScheduledTestID = scheduledTest.id
        scheduleTemplateDraft = scheduledTest.templateID
        scheduleCountDraft = scheduledTest.intervalCount
        scheduleUnitDraft = scheduledTest.intervalUnit
        scheduleIncludesInternetChecks = scheduledTest.includeInternetChecks ?? true
        showingScheduleEditor = true
    }
    @discardableResult func saveScheduledTest() -> Bool {
        guard let templateID = scheduleTemplateDraft, templates.contains(where: { $0.id == templateID }) else { return false }
        guard templates.first(where: { $0.id == templateID })?.flows.contains(where: \.selected) == true else {
            message = "Select at least one test in the selected template before scheduling."
            return false
        }
        let count = ScheduleUnit.normalizedCount(scheduleCountDraft)
        let interval = ScheduleUnit.interval(count: count, unit: scheduleUnitDraft)
        if let id = editingScheduledTestID, let index = scheduledTests.firstIndex(where: { $0.id == id }) {
            var item = scheduledTests[index]
            if item.templateID != templateID { item.lastRunAt = nil; item.lastReportID = nil }
            item.templateID = templateID
            item.intervalCount = count
            item.intervalUnit = scheduleUnitDraft
            item.includeInternetChecks = scheduleIncludesInternetChecks
            item.nextRunAt = (item.lastRunAt ?? Date()).addingTimeInterval(interval)
            scheduledTests[index] = item
        } else {
            scheduledTests.append(ScheduledTest(templateID: templateID, intervalCount: count, intervalUnit: scheduleUnitDraft, nextRunAt: Date().addingTimeInterval(interval), includeInternetChecks: scheduleIncludesInternetChecks))
        }
        showingScheduleEditor = false
        editingScheduledTestID = nil
        return true
    }
    func setScheduledTestEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = scheduledTests.firstIndex(where: { $0.id == id }) else { return }
        scheduledTests[index].isEnabled = enabled
        if enabled {
            let item = scheduledTests[index]
            scheduledTests[index].nextRunAt = Date().addingTimeInterval(ScheduleUnit.interval(count: item.intervalCount, unit: item.intervalUnit))
        }
    }
    func deleteScheduledTest(_ id: UUID) {
        scheduledTests.removeAll { $0.id == id }
    }
    func openScheduledReport(_ id: UUID?) {
        guard let id, let report = reports.first(where: { $0.id == id }) else { return }
        selectReport(report)
    }
    func scheduledTemplateName(_ schedule: ScheduledTest) -> String {
        templates.first(where: { $0.id == schedule.templateID })?.name ?? t("Missing template")
    }
    func scheduleCountdown(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
    func scheduleIntervalText(_ schedule: ScheduledTest) -> String {
        let unit = schedule.intervalCount == 1 ? ["Minutes":"minute", "Hours":"hour", "Days":"day"][schedule.intervalUnit.rawValue] ?? schedule.intervalUnit.rawValue.lowercased() : schedule.intervalUnit.rawValue.lowercased()
        return "\(schedule.intervalCount) \(t(unit))"
    }
    func start(scheduledTestID: UUID? = nil) {
        requestRun(scheduledTestID: scheduledTestID)
    }
    func requestRun(scheduledTestID: UUID? = nil) {
        guard !running, !finalizing else { return }
        pendingScheduledTestID = scheduledTestID
        if scheduledTestID != nil {
            // Scheduled runs cannot wait for consent; honor the choice saved with the schedule.
            let includePublicChecks = scheduledTestID.flatMap { id in scheduledTests.first(where: { $0.id == id })?.includeInternetChecks } ?? true
            confirmRun(includeInternetChecks: includePublicChecks)
        } else {
            showingInternetChoice = true
        }
    }
    func confirmRun(includeInternetChecks: Bool) {
        let scheduledID = pendingScheduledTestID
        pendingScheduledTestID = nil
        showingInternetChoice = false
        guard !running, selectedTemplate != nil else { return }
        let selected = flows.filter(\.selected)
        guard !selected.isEmpty else {
            if let scheduledID {
                pauseScheduledTest(scheduledID, message: "This scheduled template has no selected tests. The schedule has been paused. Select one or more tests in Templates, then enable it again.")
            } else {
                message = "No tests selected"
            }
            return
        }
        let validatedFlows: [Flow]
        do { validatedFlows = try selected.map(FlowInputValidator.normalize) }
        catch {
            if let scheduledID {
                pauseScheduledTest(scheduledID, message: "A selected test in this scheduled template is invalid. The schedule has been paused. Fix the test in Templates, then enable the schedule again.")
            } else {
                message = "One or more selected flows contain invalid destination or protocol data. Edit or re-import those flows before running the report."
            }
            return
        }
        scheduledRunTask?.cancel(); scheduledRunTask = nil
        activeScheduledTestID = scheduledID
        flows = validatedFlows; completed = 0; next = 0; retryQueue = []; generation = UUID(); nextLaunchAt = .distantPast; launchScheduled = false; running = true; finalizing = false; filterStatus = "All"
        for i in flows.indices { flows[i].status = "Pending"; flows[i].detail = ""; flows[i].milliseconds = nil; flows[i].testedAt = ""; flows[i].attempts = [] }
        internetTask = includeInternetChecks ? Task { await InternetDiagnostics.run() } : nil
        schedule(generation)
    }
    private func rescheduleAfterSkippedRun(_ id: UUID) {
        guard let index = scheduledTests.firstIndex(where: { $0.id == id }) else { return }
        let item = scheduledTests[index]
        scheduledTests[index].nextRunAt = Date().addingTimeInterval(ScheduleUnit.interval(count: item.intervalCount, unit: item.intervalUnit))
    }
    private func pauseScheduledTest(_ id: UUID, message: String) {
        guard let index = scheduledTests.firstIndex(where: { $0.id == id }) else { return }
        scheduledTests[index].isEnabled = false
        self.message = message
    }
    func cancelPendingRun() {
        if let id = pendingScheduledTestID { rescheduleAfterSkippedRun(id) }
        pendingScheduledTestID = nil
        showingInternetChoice = false
    }
    private func rescheduleAutomaticRuns() {
        guard !restoringSettings else { return }
        scheduledRunTask?.cancel(); scheduledRunTask = nil
        guard !running, !finalizing,
              let next = scheduledTests.filter({ schedule in schedule.isEnabled && templates.contains(where: { $0.id == schedule.templateID }) }).map(\.nextRunAt).min() else { return }
        let delay = max(0, next.timeIntervalSinceNow)
        scheduledRunTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledRunTask = nil
            self.launchDueScheduledTest()
        }
    }
    private func launchDueScheduledTest() {
        guard !running, !finalizing else { rescheduleAutomaticRuns(); return }
        guard let scheduled = scheduledTests.filter({ schedule in schedule.isEnabled && schedule.nextRunAt <= Date() && templates.contains(where: { $0.id == schedule.templateID }) }).min(by: { $0.nextRunAt < $1.nextRunAt }),
              let template = templates.first(where: { $0.id == scheduled.templateID }) else {
            rescheduleAutomaticRuns(); return
        }
        let selectedFlows = template.flows.filter(\.selected)
        guard !selectedFlows.isEmpty else {
            pauseScheduledTest(scheduled.id, message: "This scheduled template has no selected tests. The schedule has been paused. Select one or more tests in Templates, then enable it again.")
            return
        }
        screenBeforeScheduledRun = screen
        selectedTemplateID = template.id
        flows = template.flows
        screen = .schedules
        requestRun(scheduledTestID: scheduled.id)
    }
    private func schedule(_ token: UUID) {
        guard running, token == generation else { return }
        while probes.count < 3 && (!retryQueue.isEmpty || next < flows.count) {
            let delay = nextLaunchAt.timeIntervalSinceNow
            if delay > 0 {
                guard !launchScheduled else { return }
                launchScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == token, self.running else { return }
                    self.launchScheduled = false; self.schedule(token)
                }
                return
            }
            let index: Int
            if !retryQueue.isEmpty { index = retryQueue.removeFirst() }
            else { index = next; next += 1 }
            nextLaunchAt = Date().addingTimeInterval(testInterval)
            let flow = flows[index]; let probe = Probe(); probes[flow.id] = probe
            flows[index].status = flow.attempts.isEmpty ? "Running" : "Retrying (\(flow.attempts.count + 1)/\(RetryPolicy.maximumAttempts(retriesAfterFailure: retryCount)))"
            probe.run(flow, timeout: timeout) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token, self.running else { return }
                    self.probes.removeValue(forKey: flow.id)
                    let attempt = ProbeAttempt(number: self.flows[index].attempts.count + 1, status: result.status, detail: result.detail, milliseconds: result.milliseconds, testedAt: result.testedAt, source: result.source, certificate: result.certificate)
                    self.flows[index].attempts.append(attempt)
                    self.flows[index].status = result.status; self.flows[index].detail = result.detail; self.flows[index].milliseconds = result.milliseconds; self.flows[index].testedAt = result.testedAt
                    if RetryPolicy.shouldRetry(status: result.status, completedAttempts: self.flows[index].attempts.count, retriesAfterFailure: self.retryCount) {
                        self.flows[index].status = "Retrying (\(self.flows[index].attempts.count + 1)/\(RetryPolicy.maximumAttempts(retriesAfterFailure: self.retryCount)))"
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay) {
                            Task { @MainActor in
                                guard self.generation == token, self.running else { return }
                                self.retryQueue.append(index); self.schedule(token)
                            }
                        }
                    } else {
                        self.completed += 1
                        if self.completed == self.flows.count { self.finishReport(token) }
                    }
                    self.schedule(token)
                }
            }
        }
    }
    private func finishReport(_ token: UUID) {
        running = false; finalizing = true
        let task = internetTask
        Task { @MainActor in
            let diagnostics = await task?.value
            guard generation == token else { return }
            let report = persistReport(diagnostics)
            if let id = activeScheduledTestID, let index = scheduledTests.firstIndex(where: { $0.id == id }) {
                let completedAt = report?.createdAt ?? Date()
                scheduledTests[index].lastRunAt = completedAt
                scheduledTests[index].lastReportID = report?.id
                scheduledTests[index].nextRunAt = completedAt.addingTimeInterval(ScheduleUnit.interval(count: scheduledTests[index].intervalCount, unit: scheduledTests[index].intervalUnit))
            }
            let wasScheduled = activeScheduledTestID != nil
            activeScheduledTestID = nil
            finalizing = false
            screen = wasScheduled ? screenBeforeScheduledRun : .overview
            rescheduleAutomaticRuns()
        }
    }
    func stop() {
        running = false; finalizing = false; internetTask?.cancel(); generation = UUID(); probes.values.forEach { $0.cancel() }; probes.removeAll()
        launchScheduled = false
        if let id = activeScheduledTestID, let index = scheduledTests.firstIndex(where: { $0.id == id }) {
            let item = scheduledTests[index]
            scheduledTests[index].nextRunAt = Date().addingTimeInterval(ScheduleUnit.interval(count: item.intervalCount, unit: item.intervalUnit))
        }
        if activeScheduledTestID != nil { screen = screenBeforeScheduledRun }
        activeScheduledTestID = nil
        for i in flows.indices where flows[i].status == "Running" || flows[i].status == "Pending" { flows[i].status = "Cancelled" }
        rescheduleAutomaticRuns()
    }
    @discardableResult func persistReport(_ diagnostics: InternetDiagnostics? = nil) -> SavedReport? {
        do {
            try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
            let report = SavedReport(id: UUID(), name: "\(t("Network report")) — \(DateFormatter.reportName.string(from: Date()))", createdAt: Date(), flows: flows, folderID: selectedReportFolderID, publicIP: diagnostics?.publicIP, internetStatus: diagnostics?.status, internetChecks: diagnostics?.checks)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(report), to: reportFolder.appendingPathComponent(report.id.uuidString + ".json"))
            reports.append(report); reports.sort { $0.createdAt > $1.createdAt }; selectedReportID = report.id
            return report
        } catch { message = error.localizedDescription; return nil }
    }
    func loadReportFolders() {
        let url = reportFolder.appendingPathComponent("folders.json")
        try? AppDataStore.restrictPermissions(at: url)
        if let data = try? Data(contentsOf: url), let decoded = try? AppDataStore.decoder.decode([ReportFolder].self, from: data) { reportFolders = decoded }
    }
    func saveReportFolders() {
        do {
            try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
            try AppDataStore.writePrivate(JSONEncoder.pretty.encode(reportFolders), to: reportFolder.appendingPathComponent("folders.json"))
        } catch { message = error.localizedDescription }
    }
    func createReportFolder() {
        let name = reportFolderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !reportFolders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        let folder = ReportFolder(name: name); reportFolders.append(folder); saveReportFolders(); selectedReportFolderID = folder.id; screen = .history; reportFolderNameDraft = ""
    }
    func beginRenameReportFolder(_ folder: ReportFolder) {
        reportFolderRenameID = folder.id; reportFolderNameDraft = folder.name; showingRenameReportFolder = true
    }
    func renameReportFolder() {
        guard let id = reportFolderRenameID, let index = reportFolders.firstIndex(where: { $0.id == id }) else { return }
        let name = reportFolderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !reportFolders.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        reportFolders[index].name = name; saveReportFolders(); reportFolderNameDraft = ""; reportFolderRenameID = nil
    }
    func deleteReportFolder(_ folder: ReportFolder) {
        for var report in reports where report.folderID == folder.id {
            report.folderID = nil
            saveReport(report)
        }
        reportFolders.removeAll { $0.id == folder.id }; saveReportFolders()
        if selectedReportFolderID == folder.id { selectedReportFolderID = nil; screen = .history }
    }
    func moveReport(_ report: SavedReport, to folderID: UUID?) {
        var changed = report; changed.folderID = reportFolders.contains(where: { $0.id == folderID }) ? folderID : nil; saveReport(changed)
    }
    func importReportsCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = true
        panel.message = t("Import report CSV files exported by NetworkPortEval.")
        let source = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        source.placeholderString = t("Source computer (optional)")
        panel.accessoryView = source
        guard panel.runModal() == .OK else { return }
        var importedCount = 0, duplicates = 0
        var errors: [String] = []
        for url in panel.urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 { throw CSV.error("Maximum: 5 MB per CSV.") }
                var report = try ReportCSVImport.parse(Data(contentsOf: url), filename: url.lastPathComponent, computer: source.stringValue)
                if ReportCSVImport.isDuplicate(report, in: reports) { duplicates += 1; continue }
                report.folderID = selectedReportFolderID
                try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
                try AppDataStore.writePrivate(JSONEncoder.pretty.encode(report), to: reportFolder.appendingPathComponent(report.id.uuidString + ".json"))
                reports.append(report); importedCount += 1
            } catch { errors.append("\(url.lastPathComponent): \(t(error.localizedDescription))") }
        }
        reports.sort { $0.createdAt > $1.createdAt }
        messageTitle = errors.isEmpty ? "Import complete" : "Import results"
        message = "\(t("Imported reports")): \(importedCount) · \(t("Duplicates skipped")): \(duplicates)" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
    }
    func loadReports() {
        do {
            try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(at: reportFolder, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "folders.json" }
            for url in urls { try? AppDataStore.restrictPermissions(at: url) }
            var loaded: [SavedReport] = []
            var failures: [String] = []
            for url in urls {
                do { loaded.append(try AppDataStore.decoder.decode(SavedReport.self, from: Data(contentsOf: url))) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            reports = loaded.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
            if !failures.isEmpty { message = failures.joined(separator: "\n") }
            selectedReportID = reports.first?.id
            selectedReportIDs = []
        } catch { message = error.localizedDescription }
    }
    func selectReport(_ report: SavedReport) { selectedReportID = report.id; flows = report.flows; filterStatus = "All"; screen = .overview }
    func saveReport(_ report: SavedReport) {
        do { try AppDataStore.writePrivate(JSONEncoder.pretty.encode(report), to: reportFolder.appendingPathComponent(report.id.uuidString + ".json")); if let i = reports.firstIndex(where: {$0.id == report.id}) { reports[i] = report }; reports.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt } }
        catch { message = error.localizedDescription }
    }
    func renameSelectedReport() { guard var r = selectedReport else { return }; let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; r.name = name; saveReport(r); draftName = "" }
    func deleteReport(_ report: SavedReport) {
        do {
            try FileManager.default.removeItem(at: reportFolder.appendingPathComponent(report.id.uuidString + ".json"))
            reports.removeAll { $0.id == report.id }
            selectedReportIDs.remove(report.id)
            for index in scheduledTests.indices where scheduledTests[index].lastReportID == report.id { scheduledTests[index].lastReportID = nil }
            selectedReportID = reports.first?.id
            if let next = selectedReport { flows = next.flows } else { flows = [] }
        }
        catch { message = error.localizedDescription }
    }
    func selectReportFolder(_ id: UUID?) {
        selectedReportFolderID = id
        selectedReportID = nil
        selectedReportIDs = []
        screen = .history
    }
    func toggleReportSelection(_ id: UUID, selected: Bool) {
        if selected { selectedReportIDs.insert(id) } else { selectedReportIDs.remove(id) }
    }
    func toggleVisibleReportSelection() {
        let visibleIDs = Set(visibleReports.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        selectedReportIDs = VisibleItemSelection.toggleAll(visibleIDs: visibleIDs, selectedIDs: selectedReportIDs)
    }
    func reportFolderName(for report: SavedReport) -> String {
        guard let folderID = report.folderID,
              let folder = reportFolders.first(where: { $0.id == folderID }) else { return t("Unfiled") }
        return folder.name
    }
    func deleteSelectedReports() {
        let visibleIDs = Set(visibleReports.map(\.id))
        let selectedVisibleIDs = VisibleItemSelection.selectedVisibleIDs(visibleIDs: visibleIDs, selectedIDs: selectedReportIDs)
        let targets = reports.filter { selectedVisibleIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var failedIDs = Set<UUID>()
        for report in targets {
            do {
                try FileManager.default.removeItem(at: reportFolder.appendingPathComponent(report.id.uuidString + ".json"))
                reports.removeAll { $0.id == report.id }
                for index in scheduledTests.indices where scheduledTests[index].lastReportID == report.id { scheduledTests[index].lastReportID = nil }
                if selectedReportID == report.id { selectedReportID = nil }
            } catch {
                failedIDs.insert(report.id)
                message = error.localizedDescription
            }
        }
        selectedReportIDs = failedIDs
        if let selectedReportID, let report = reports.first(where: { $0.id == selectedReportID }) { flows = report.flows }
        else if selectedReportID == nil, let next = reports.first { selectedReportID = next.id; flows = next.flows }
        else if reports.isEmpty { selectedReportID = nil; flows = [] }
    }
    func chooseReportsFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = t("Save")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); reportFolder = url; UserDefaults.standard.set(url.path, forKey: "reportsFolder"); saveSettingsSnapshot(); loadReportFolders(); loadReports() } catch { message = error.localizedDescription }
    }
    func standardReportsFolder() { reportFolder = defaultReportsFolder; UserDefaults.standard.removeObject(forKey: "reportsFolder"); saveSettingsSnapshot(); loadReportFolders(); loadReports() }
    func openExportsFolder() {
        guard let lastExportFolder else { message = "Export a file first to set its folder."; return }
        NSWorkspace.shared.open(lastExportFolder)
    }
    private func rememberExportLocation(_ fileURL: URL) {
        let folder = fileURL.deletingLastPathComponent()
        lastExportFolder = folder
        UserDefaults.standard.set(folder.path, forKey: "lastExportFolder")
        saveSettingsSnapshot()
    }
    func reportCSV(_ report: SavedReport) -> String {
        let translatedChecks = (report.internetChecks ?? []).map { check in
            InternetCheck(service: check.service, result: t(check.result), httpStatus: check.httpStatus, detail: t(check.detail), source: check.source, certificate: check.certificate)
        }
        return CSV.export(report.flows.map { f in
            var copy = f
            copy.status = t(copy.status); copy.detail = t(copy.detail)
            copy.attempts = f.attempts.map { attempt in
                var translated = attempt; translated.status = t(attempt.status); translated.detail = t(attempt.detail); return translated
            }
            return copy
        }, reportName: report.name, createdAt: report.createdAt, publicIP: report.publicIP ?? t(report.internetStatus == nil ? "Not checked" : "Unavailable"), internetStatus: report.internetStatus.map(t), internetChecks: translatedChecks, translate: t, reportID: report.imported?.originalID ?? report.id, sourceMetadata: report.imported?.metadata ?? [:])
    }
    func reportText(_ report: SavedReport) -> String {
        let network = ReportNetworkHeader(flows: report.flows, internetChecks: report.internetChecks ?? [])
        var lines = [
            "NetworkPortEval — \(report.name)",
            "\(t("Date:")) \(DateFormatter.reportDate.string(from: report.createdAt))",
            "\(t("Tests:")) \(report.flows.count) · \(t("Completed:")) \(report.flows.filter { ["Open","Closed","Error","Inconclusive"].contains($0.status) }.count) · \(t("Failed/inconclusive:")) \(report.failures)",
            "\n\(t("Report information"))",
            "\(t("Internet status:")) \(t(report.internetStatus ?? "Not checked"))",
            "\(t("Public IP (api.ipify.org):")) \(report.publicIP ?? t(report.internetStatus == nil ? "Not checked" : "Unavailable"))",
            "\(t("Source IP / MAC:")) \(network.sourceIPs) / \(network.sourceMACs)",
            "\(t("Interface / connection:")) \(network.interfaces) [\(network.physicalInterfaces)] · \(network.connectionTypes)",
            "\(t("VPN active:")) \(network.vpnStates.components(separatedBy: "; ").map(t).joined(separator: "; "))",
            "\(t("System proxy used:")) \(network.proxyStates.map { $0.components(separatedBy: "; ").map(t).joined(separator: "; ") } ?? t("Proxy use unknown"))",
            "\(t("Configured DNS servers:")) \(network.dnsServers)",
            "\n\(t("Internet checks"))"
        ]
        if let origin = report.imported {
            lines.append("\n" + t("Imported") + " · " + origin.filename + " · " + (origin.computer ?? ""))
            lines.append(t("Imported results; no tests were run on this Mac."))
            lines += origin.metadata.keys.sorted().map { t($0) + ": " + (origin.metadata[$0] ?? "") }
        }
        for check in report.internetChecks ?? [] {
            let certificate = check.certificate.map { "TLS \($0.trusted ? t("valid") : t("invalid")) \(t("for")) \($0.host) · \($0.subject) ·  \(t("issuer")) \($0.issuer) ·  \(t("expires")) \($0.expiresAt) · SHA-256 \($0.sha256)" } ?? t("TLS certificate unavailable")
            lines.append("\(check.service): \(t(check.result))\(check.httpStatus.map { " (HTTP \($0))" } ?? "") — \(check.detail) · \(certificate)")
        }
        lines.append(t("Hostnames use the macOS system DNS resolver. Configured servers are listed, but macOS does not report which one answered a lookup. You cannot choose a DNS server in NetworkPortEval."))
        lines.append("\n\(t("Test results"))")
        lines.append(["Category", "Name", "Comment", "Host", "Port", "Protocol", "Attempt", "TLS certificate", "Status", "Latency", "Details"].map(t).joined(separator: " | "))
        for flow in report.flows {
            let attempts = flow.attempts.isEmpty ? [ProbeAttempt(number: 0, status: flow.status, detail: flow.detail, milliseconds: flow.milliseconds, testedAt: flow.testedAt)] : flow.attempts
            for attempt in attempts {
                let certificate = attempt.certificate.map { "\($0.trusted ? t("Valid") : t("Invalid")) \(t("for")) \($0.host) · \($0.subject) ·  \(t("issuer")) \($0.issuer) ·  \(t("expires")) \($0.expiresAt) · SHA-256 \($0.sha256)" } ?? t("Not requested for this protocol")
                lines.append("\(flow.category) | \(flow.name) | \(flow.comment) | \(flow.host) | \(flow.port) | \(flow.proto) | \(attempt.number == 0 ? "—" : String(attempt.number)) | \(certificate) | \(t(attempt.status)) | \(attempt.milliseconds.map { "\($0) ms" } ?? "—") | \(t(attempt.detail))")
            }
        }
        return lines.joined(separator: "\n")
    }
    func exportSelected() {
        guard let report = selectedReport else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = safeFilename(exportName) + "." + exportFormat.rawValue.lowercased()
        panel.directoryURL = lastExportFolder
        switch exportFormat { case .csv: panel.allowedContentTypes = [.commaSeparatedText]; case .txt: panel.allowedContentTypes = [.plainText]; case .pdf: panel.allowedContentTypes = [.pdf]; case .json: panel.allowedContentTypes = [.json] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch exportFormat {
            case .csv: try reportCSV(report).write(to: url, atomically: true, encoding: .utf8)
            case .txt: try reportText(report).write(to: url, atomically: true, encoding: .utf8)
            case .json:
                let checks = report.internetChecks ?? []
                let completedCount = report.flows.filter { ["Open", "Closed", "Error", "Inconclusive"].contains($0.status) }.count
                let failedCount = report.failures
                let document = ReportJSONDocument(
                    importedSourceMetadata: report.imported?.metadata,
                    importedFilename: report.imported?.filename,
                    reportName: report.name,
                    createdAt: report.createdAt,
                    summary: ReportJSONSummary(testCount: report.flows.count, completed: completedCount, failed: failedCount),
                    publicIP: report.publicIP,
                    internetStatus: report.internetStatus,
                    internetChecks: checks,
                    network: ReportNetworkHeader(flows: report.flows, internetChecks: checks),
                    tests: report.flows.map(ReportJSONTest.init(flow:))
                )
                try JSONEncoder.pretty.encode(document).write(to: url, options: .atomic)
            case .pdf: try PDFReport.write(report, to: url, locale: Locale(identifier: languageCode), translate: t)
            }
            rememberExportLocation(url)
        } catch { message = error.localizedDescription }
    }
    func beginExportSelectedReport() {
        guard let report = selectedReport else { return }
        exportName = report.name; exportFormat = .csv; showExport = true
    }
    private func safeFilename(_ s: String) -> String { let safe = s.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines); return safe.isEmpty ? "Network report" : safe }
}

struct ContentView: View {
    @EnvironmentObject private var model: Model
    var body: some View {
        NavigationSplitView {
            List(selection: $model.screen) {
                Section(model.t("Workspace")) {
                    workspaceLabel("Templates", symbol: "checklist", color: .blue).tag(Screen.templates)
                    workspaceLabel("Overview", symbol: "chart.bar.xaxis", color: .purple).tag(Screen.overview).disabled(model.selectedReport == nil)
                    workspaceLabel("Results", symbol: "list.bullet.rectangle", color: .teal).tag(Screen.results).disabled(model.selectedReport == nil)
                    workspaceLabel("Scheduled tests", symbol: "calendar.badge.clock", color: .orange).tag(Screen.schedules)
                }
                Section {
                    Button { model.selectReportFolder(nil) } label: { Label("\(model.t("All Reports")) · \(model.reports.count)", systemImage: "tray.full") }
                    ForEach(model.sortedReportFolders) { folder in
                        Button { model.selectReportFolder(folder.id) } label: {
                            Label(folder.name + " · " + String(model.reports.filter { $0.folderID == folder.id }.count), systemImage: "folder")
                        }
                        .contextMenu {
                            Button(model.t("Rename folder")) { model.beginRenameReportFolder(folder) }
                            Button(model.t("Delete folder"), role: .destructive) { model.reportFolderDeleteTarget = folder }
                        }
                    }
                } header: {
                    HStack { Text(model.t("Reports")); Spacer(); Button { model.reportFolderNameDraft = ""; model.showingNewReportFolder = true } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.borderless).help(model.t("New report folder")) }
                }
            }.navigationTitle("NetworkPortEval")
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch model.screen {
                case .templates: templatesView
                case .schedules: schedulesView
                case .overview: overviewView
                case .results: resultsView
                case .history: reportsView
                }
                Spacer(minLength: 0)
                footer
            }.padding(24).frame(minWidth: 850, minHeight: 600)
        }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) {
            if model.screen == .templates {
                Button { model.requestRun() } label: { Label(model.t("Play"), systemImage: model.running || model.finalizing ? "hourglass" : "play.fill") }.buttonStyle(.borderedProminent).disabled(model.running || model.finalizing || model.flows.filter(\.selected).isEmpty)
            }
        }}
        .alert(model.t("Rename"), isPresented: $model.renameReportPrompt) { TextField(model.t("Report name"), text: $model.draftName); Button(model.t("Cancel"), role: .cancel) {}; Button(model.t("Save")) { model.renameSelectedReport() } } message: { Text(model.t("Report name")) }
        .alert(model.t("New blank template"), isPresented: $model.newTemplatePrompt) {
            TextField(model.t("Template name"), text: $model.newTemplateName)
            Button(model.t("Cancel"), role: .cancel) { model.newTemplateName = "" }
            Button(model.t("Create")) { model.createBlankTemplate() }.disabled(model.newTemplateError != nil)
        } message: {
            Text(model.newTemplateName.isEmpty ? model.t("Create an empty template, then add your tests manually.") : (model.newTemplateError ?? model.t("Create an empty template, then add your tests manually.")))
        }
        .alert(model.t("Save template"), isPresented: $model.templateNamePrompt) { TextField(model.t("Template name"), text: $model.draftName); Button(model.t("Cancel"), role: .cancel) {}; Button(model.t("Save")) { model.saveCurrentAsTemplate() } } message: { Text(model.t("Template name")) }
        .confirmationDialog(model.t("Delete this template?"), isPresented: Binding(get: { model.templateDeleteTarget != nil }, set: { if !$0 { model.templateDeleteTarget = nil } }), titleVisibility: .visible) {
            Button(model.t("Delete template"), role: .destructive) { if let template = model.templateDeleteTarget { model.deleteTemplate(template.id) }; model.templateDeleteTarget = nil }
            Button(model.t("Cancel"), role: .cancel) { model.templateDeleteTarget = nil }
        } message: { Text(model.t("Any schedules using this template will also be deleted. Existing reports will be kept.")) }
        .alert(model.t(model.messageTitle), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button(model.t("Close")) { model.message = nil } } message: { Text(model.t(model.message ?? "")) }
        .sheet(isPresented: $model.showExport) { ExportSheet().environmentObject(model) }
        .sheet(isPresented: $model.showRename) { RenameSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingCategoryManager) { CategoryManagerSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingFlowEditor) { FlowEditorSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingScheduleEditor) { ScheduledTestEditorSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingEmailRecipients) { EmailRecipientsSheet().environmentObject(model) }
        .sheet(isPresented: $model.showingHelp) { HelpContactSheet().environmentObject(model) }
        .alert(model.t("New report folder"), isPresented: $model.showingNewReportFolder) { TextField(model.t("Folder name"), text: $model.reportFolderNameDraft); Button(model.t("Cancel"), role: .cancel) {}; Button(model.t("Create")) { model.createReportFolder() } } message: { Text(model.t("Reports in a deleted folder return to All Reports.")) }
        .alert(model.t("Rename folder"), isPresented: $model.showingRenameReportFolder) { TextField(model.t("Folder name"), text: $model.reportFolderNameDraft); Button(model.t("Cancel"), role: .cancel) { model.reportFolderRenameID = nil }; Button(model.t("Save")) { model.renameReportFolder() } } message: { Text(model.t("Folder name")) }
        .confirmationDialog(model.t("Delete folder?"), isPresented: Binding(get: { model.reportFolderDeleteTarget != nil }, set: { if !$0 { model.reportFolderDeleteTarget = nil } }), titleVisibility: .visible) {
            Button(model.t("Delete folder"), role: .destructive) { if let folder = model.reportFolderDeleteTarget { model.deleteReportFolder(folder) }; model.reportFolderDeleteTarget = nil }
            Button(model.t("Cancel"), role: .cancel) { model.reportFolderDeleteTarget = nil }
        } message: { Text(model.t("Reports in a deleted folder return to All Reports.")) }
        .confirmationDialog(model.t("Delete selected reports?"), isPresented: $model.showingBulkDeleteConfirmation, titleVisibility: .visible) {
            Button(model.t("Delete"), role: .destructive) { model.deleteSelectedReports() }
            Button(model.t("Cancel"), role: .cancel) {}
        } message: { Text(model.t("This permanently deletes the selected reports and cannot be undone.")) }
        .confirmationDialog(model.t("Delete"), isPresented: Binding(get: { model.deleteTarget != nil }, set: { if !$0 { model.deleteTarget = nil } }), titleVisibility: .visible) { Button(model.t("Delete"), role: .destructive) { if let item = model.deleteTarget { model.deleteReport(item) }; model.deleteTarget = nil }; Button(model.t("Cancel"), role: .cancel) { model.deleteTarget = nil } }
        .confirmationDialog(model.t("Delete flow?"), isPresented: Binding(get: { model.flowDeleteTarget != nil }, set: { if !$0 { model.flowDeleteTarget = nil } }), titleVisibility: .visible) {
            Button(model.t("Delete flow"), role: .destructive) { if let id = model.flowDeleteTarget { model.removeFlow(id) }; model.flowDeleteTarget = nil }
            Button(model.t("Cancel"), role: .cancel) { model.flowDeleteTarget = nil }
        }
        .confirmationDialog(model.t("Delete schedule?"), isPresented: Binding(get: { model.scheduleDeleteTarget != nil }, set: { if !$0 { model.scheduleDeleteTarget = nil } }), titleVisibility: .visible) {
            Button(model.t("Delete schedule"), role: .destructive) { if let item = model.scheduleDeleteTarget { model.deleteScheduledTest(item.id) }; model.scheduleDeleteTarget = nil }
            Button(model.t("Cancel"), role: .cancel) { model.scheduleDeleteTarget = nil }
        }
        .confirmationDialog(model.t("Internet checks for this report?"), isPresented: Binding(get: { model.showingInternetChoice }, set: { if !$0 { model.cancelPendingRun() } }), titleVisibility: .visible) {
            Button(model.t("Run with public internet checks")) { model.confirmRun(includeInternetChecks: true) }
            Button(model.t("Run without public internet checks")) { model.confirmRun(includeInternetChecks: false) }
            Button(model.t("Cancel"), role: .cancel) { model.cancelPendingRun() }
        } message: { Text(model.t("Only run tests on destinations you are authorized to test.") + "\n\n" + model.selectedDestinationDisclosure + "\n\n" + model.t("Google, Apple and api.ipify.org receive requests from your public IP. Choose whether to include these checks in this report.")) }
    }
    private func workspaceLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label {
            Text(model.t(title))
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
    }
    var header: some View {
        HStack {
            Image(systemName: "network").font(.system(size: 30)).foregroundStyle(.blue)
            VStack(alignment: .leading) { Text("NetworkPortEval").font(.largeTitle.bold()); Text(model.t("Network evaluation utility for Mac devices")).foregroundStyle(.secondary) }
            Spacer()
            languagePicker
            if model.running || model.finalizing { ProgressView(value: Double(model.completed), total: Double(max(1, model.flows.count))).frame(width: 180); if model.running { Button(model.t("Stop")) { model.stop() } } }
        }
    }
    private var languagePicker: some View {
        Menu {
            ForEach(Language.allCases, id: \.rawValue) { language in
                Button {
                    model.languageCode = language.rawValue
                } label: {
                    if model.language == language { Label(language.title, systemImage: "checkmark") }
                    else { Text(language.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                Text(model.t("Language"))
                Text(model.language.title).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .help("\(model.t("Language")): \(model.language.title)")
        .accessibilityLabel("\(model.t("Language")): \(model.language.title)")
    }
    @ViewBuilder private func reportRow(_ report: SavedReport) -> some View {
        Button { model.selectReport(report) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.name).lineLimit(1)
                Text("\(report.flows.count) · \(DateFormatter.reportDate.string(from: report.createdAt))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(model.t("Rename")) { model.selectedReportID = report.id; model.draftName = report.name; model.renameReportPrompt = true }
            Menu(model.t("Move to folder")) {
                Button(model.t("No folder")) { model.moveReport(report, to: nil) }
                ForEach(model.reportFolders) { folder in Button(folder.name) { model.moveReport(report, to: folder.id) } }
            }
            Button(model.t("Delete"), role: .destructive) { model.deleteTarget = report }
        }
    }
    var templatesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.t("Templates")).font(.title2.bold()); Spacer(); Button { model.newTemplateName = ""; model.newTemplatePrompt = true } label: { Label(model.t("New template"), systemImage: "doc.badge.plus") }.disabled(model.running || model.finalizing); Button(model.t("Manage categories")) { model.showingCategoryManager = true }.disabled(model.running || model.finalizing); Button { model.beginAddFlow() } label: { Label(model.t("Add flow"), systemImage: "plus") }.disabled(model.running || model.finalizing); if !model.flows.isEmpty { Button(model.t("Save template")) { model.draftName = ""; model.templateNamePrompt = true }.disabled(model.running || model.finalizing) } }
            HStack(spacing: 10) {
                Picker(model.t("Template name"), selection: Binding(get: { model.selectedTemplateID }, set: { model.selectTemplate($0) })) { ForEach(model.templates) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 380).disabled(model.running || model.finalizing)
                Button(model.t("Delete template"), systemImage: "trash") { model.templateDeleteTarget = model.selectedTemplate }
                    .disabled(model.running || model.finalizing || model.templates.count <= 1 || model.selectedTemplate == nil)
                    .help(model.templates.count <= 1 ? model.t("At least one template must remain.") : model.t("Delete template"))
                Spacer(minLength: 8)
                Menu {
                    Button { model.createTemplateFromCSV() } label: { Label(model.t("Import flows from CSV…"), systemImage: "square.and.arrow.down") }
                    Button { model.exportSelectedTemplateCSV() } label: { Label(model.t("Export current template…"), systemImage: "square.and.arrow.up") }.disabled(model.selectedTemplate == nil)
                    Divider()
                    Button { model.exportBlankTemplateCSV() } label: { Label(model.t("Download blank CSV template…"), systemImage: "doc.badge.plus") }
                    Button { model.exportSampleTemplateCSV() } label: { Label(model.t("Download sample CSV"), systemImage: "doc.text") }
                } label: { Label(model.t("Template files"), systemImage: "tablecells") }
                .help(model.t("Import or export reusable test templates as CSV files."))
                .disabled(model.running || model.finalizing)
            }
            if model.flows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("This template is empty.")).font(.headline)
                    Text(model.t("Add your first test by entering its destination, port and protocol.")).foregroundStyle(.secondary)
                    Button { model.beginAddFlow() } label: { Label(model.t("Add a test"), systemImage: "plus") }.disabled(model.running || model.finalizing)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(model.t("Select tests to include in this run")).foregroundStyle(.secondary)
            if let warning = model.largeRunWarning(for: model.selectedFlowCount) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { model.setAllCategorySelection(model.allCategoriesSelection != true) } label: {
                    Image(systemName: model.allCategoriesSelection == nil ? "minus.square.fill" : model.allCategoriesSelection == true ? "checkmark.square.fill" : "square")
                        .foregroundColor(model.allCategoriesSelection == false ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.t(model.allCategoriesSelection == true ? "Deselect all categories" : "Select all categories"))
                .help(model.t("Select or clear every flow in this template."))
                .disabled(model.running || model.finalizing || model.flows.isEmpty)
                Text(model.t("All categories"))
                Spacer()
                Text(model.t("Expand or collapse category flows")).font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(model.currentCategories + (model.flows.contains(where: { $0.category.isEmpty }) ? [""] : []), id: \.self) { category in
                    let selection = model.categorySelection(category)
                    Section {
                        if !model.isCategoryCollapsed(category) { ForEach(model.flows.filter { $0.category == category }) { flow in
                            HStack {
                                Toggle(isOn: Binding(get: { model.flows.first(where: { $0.id == flow.id })?.selected ?? false }, set: { model.setFlowSelection(flow.id, $0) })) { EmptyView() }.labelsHidden().disabled(model.running || model.finalizing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(flow.name.isEmpty ? flow.host : flow.name).fontWeight(.medium)
                                    Text("\(flow.host):\(flow.port) · \(flow.proto)").font(.caption).foregroundStyle(.secondary)
                                    if !flow.comment.isEmpty { Text(flow.comment).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(); Text(model.t(flow.status)).foregroundStyle(.secondary)
                                Button { model.beginEditFlow(flow.id) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help(model.t("Edit flow")).disabled(model.running || model.finalizing)
                                Button(role: .destructive) { model.flowDeleteTarget = flow.id } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(model.t("Delete flow")).disabled(model.running || model.finalizing)
                            }
                        } }
                    } header: {
                        CategorySelectionHeader(category: category, selection: selection, isCollapsed: model.isCategoryCollapsed(category))
                    }
                }
            }.listStyle(.inset).overlay { if model.flows.isEmpty { VStack(spacing: 10) { Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.secondary); Text(model.t("Import a CSV to get started")); Text(model.t("Choose a CSV containing host, port and protocol columns.")).foregroundStyle(.secondary) } } }
            VStack(alignment: .leading, spacing: 4) {
                GroupBox(model.t("Run settings")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .topLeading)], alignment: .leading, spacing: 6) {
                        settingControl("Timeout per attempt", description: "Maximum time to wait for one test attempt.") {
                            Picker(model.t("Timeout per attempt"), selection: $model.timeout) { ForEach([2.0, 5.0, 10.0, 20.0], id: \.self) { Text("\(Int($0)) s").tag($0) } }.labelsHidden()
                        }
                        settingControl("Delay between test starts", description: "Minimum pause before starting the next test. Zero delay is not available.") {
                            Picker(model.t("Delay between test starts"), selection: $model.testInterval) { ForEach([0.5, 1.0, 2.0], id: \.self) { value in Text(value == 0.5 ? "0.5 s" : "\(Int(value)) s").tag(value) } }.labelsHidden()
                        }
                        settingControl("Wait before retry", description: "Pause before repeating a failed or inconclusive test.") {
                            Picker(model.t("Wait before retry"), selection: $model.retryDelay) { ForEach([0.0, 1.0, 2.0, 5.0], id: \.self) { Text("\(Int($0)) s").tag($0) } }.labelsHidden()
                        }
                        settingControl("Retries after failure", description: "Extra attempts after the first one; 3 retries allow up to 4 attempts.") {
                            Picker(model.t("Retries after failure"), selection: $model.retryCount) { ForEach(0...5, id: \.self) { Text(String($0)).tag($0) } }.labelsHidden()
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .disabled(model.running || model.finalizing)
        }
        .onAppear { if !model.running, let template = model.selectedTemplate { model.flows = template.flows } }
    }
    var schedulesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("Scheduled tests")).font(.title2.bold())
                    Text(model.t("Create schedules that run a selected template periodically while the app is open."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.beginAddScheduledTest() } label: { Label(model.t("New schedule"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(model.templates.isEmpty)
            }
            if model.scheduledTests.isEmpty {
                ContentUnavailableView(model.t("No scheduled tests"), systemImage: "calendar.badge.clock", description: Text(model.t("Add a schedule to run a template periodically while NetworkPortEval is open.")))
                Spacer()
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    List {
                        ForEach(model.scheduledTests.sorted { $0.nextRunAt < $1.nextRunAt }) { schedule in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(model.scheduledTemplateName(schedule)).font(.headline)
                                    Text("· \(model.t("Interval:")) \(model.scheduleIntervalText(schedule))").foregroundStyle(.secondary)
                                    Text("· \(model.t((schedule.includeInternetChecks ?? true) ? "Public checks on" : "Public checks off"))").foregroundStyle(.secondary)
                                    Spacer()
                                    Toggle(model.t("Enabled"), isOn: Binding(get: { schedule.isEnabled }, set: { model.setScheduledTestEnabled(schedule.id, $0) })).labelsHidden().toggleStyle(.switch)
                                }
                                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                                    GridRow {
                                        VStack(alignment: .leading) { Text(model.t("Last test")).font(.caption).foregroundStyle(.secondary); Text(schedule.lastRunAt.map(DateFormatter.reportDate.string(from:)) ?? model.t("Never")) }
                                        VStack(alignment: .leading) { Text(model.t("Next test")).font(.caption).foregroundStyle(.secondary); Text(schedule.isEnabled ? "\(DateFormatter.reportDate.string(from: schedule.nextRunAt)) · \(model.t("in")) \(model.scheduleCountdown(schedule.nextRunAt, now: context.date))" : model.t("Paused")) }
                                    }
                                }
                                HStack {
                                    Button { model.openScheduledReport(schedule.lastReportID) } label: { Label(model.t("Open last report"), systemImage: "doc.text.magnifyingglass") }.disabled(schedule.lastReportID == nil)
                                    Spacer()
                                    Button(model.t("Edit")) { model.beginEditScheduledTest(schedule) }
                                    Button(model.t("Delete"), role: .destructive) { model.scheduleDeleteTarget = schedule }
                                }
                            }.padding(.vertical, 8)
                        }
                    }.listStyle(.inset)
                }
            }
            Text(model.t("Schedules run only while the app is open. If another report is running, a scheduled test waits until it finishes."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func settingControl<Control: View>(_ title: String, description: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.t(title)).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            control().frame(maxWidth: .infinity, alignment: .leading).help(model.t(description))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(model.t(description))
    }
    var overviewView: some View {
        Group {
            if let report = model.selectedReport {
                VStack(alignment: .leading, spacing: 20) {
                    if let origin = report.imported {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(model.t("Imported"), systemImage: "square.and.arrow.down").font(.headline)
                            Text(origin.filename + " · " + model.t("Imported on") + " " + DateFormatter.reportDate.string(from: origin.importedAt))
                            if let computer = origin.computer, !computer.isEmpty { Text(model.t("Source computer") + ": " + computer) }
                            Text(model.t("Imported results; no tests were run on this Mac.")).font(.caption)
                            DisclosureGroup(model.t("Source report information")) {
                                ForEach(origin.metadata.keys.sorted(), id: \.self) { key in Text(model.t(key) + ": " + (origin.metadata[key] ?? "")).font(.caption).textSelection(.enabled) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.t("Public Internet diagnostics (app-added)")).font(.subheadline.weight(.semibold))
                        Text(model.t("These checks are separate from the network flows selected in Templates.")).font(.caption).foregroundStyle(.secondary)
                        Text(model.t(report.internetStatus ?? "Not checked")).font(.headline)
                        Text(model.t("Public IP (api.ipify.org):") + " " + (report.publicIP ?? model.t(report.internetStatus == nil ? "Not checked" : "Unavailable"))).font(.subheadline)
                        ForEach(Array((report.internetChecks ?? []).enumerated()), id: \.offset) { _, check in
                            Text("\(check.service): \(model.t(check.result))\(check.httpStatus.map { " · HTTP \($0)" } ?? "") · \(check.source.sourceIP.isEmpty ? "Unknown" : check.source.sourceIP) · TLS \(check.certificate.map { model.t($0.trusted ? "Valid" : "Invalid") } ?? "—")").font(.caption).foregroundStyle(.secondary)
                                .help("Certificate: \(check.certificate?.subject ?? "Unavailable") · issuer \(check.certificate?.issuer ?? "Unknown") · expires \(check.certificate?.expiresAt ?? "Unknown") · SHA-256 \(check.certificate?.sha256 ?? "Unknown") · MAC \(check.source.sourceMAC) · \(check.source.interfaceName) [\(check.source.physicalInterfaceName)] · \(check.source.connectionType) · VPN \(check.source.vpnActive.map { $0 ? "Yes" : "No" } ?? "Unknown") · DNS \(check.source.dnsServers.joined(separator: ", "))")
                        }
                        Text(model.t("Each web check contacts its named public service. The local MAC is not sent to remote hosts.")).font(.caption2).foregroundStyle(.secondary)
                        Text(model.t("Hostnames use the macOS system DNS resolver. Configured servers are listed, but macOS does not report which one answered a lookup. You cannot choose a DNS server in NetworkPortEval.")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    HStack { VStack(alignment: .leading) { Text(report.name).font(.title.bold()); Text(DateFormatter.reportDate.string(from: report.createdAt)).foregroundStyle(.secondary) }; Spacer(); Button(model.t("Export…")) { exportReport(report) }.buttonStyle(.borderedProminent); Button { model.beginEmailReport() } label: { Label(model.t("Email report"), systemImage: "envelope") } }
                    Label(model.t("Review report before sharing"), systemImage: "exclamationmark.shield.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(model.t("The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending.")).font(.caption).foregroundStyle(.secondary)
                    HStack { Text(model.t("Folder")); Picker(model.t("Folder"), selection: Binding(get: { report.folderID?.uuidString ?? "" }, set: { model.moveReport(report, to: UUID(uuidString: $0)) })) { Text(model.t("No folder")).tag(""); ForEach(model.reportFolders) { folder in Text(folder.name).tag(folder.id.uuidString) } }.labelsHidden().frame(maxWidth: 240) }
                    HStack(spacing: 12) {
                        metric(model.t("Completed"), "\(report.flows.filter { ["Open","Closed","Error","Inconclusive"].contains($0.status) }.count)", "checkmark.circle.fill", .green) { model.filterStatus = "All"; model.flows = report.flows; model.screen = .results }
                        metric(model.t("Failed"), "\(report.failures)", "xmark.circle.fill", .red) { model.filterStatus = "Failed"; model.flows = report.flows; model.screen = .results }
                        metric(model.t("Open"), "\(report.flows.filter { $0.status == "Open" }.count)", "checkmark.square.fill", .blue) { model.filterStatus = "Open"; model.flows = report.flows; model.screen = .results }
                        metric(model.t("Inconclusive"), "\(report.flows.filter { $0.status == "Inconclusive" }.count)", "questionmark.square.fill", .orange) { model.filterStatus = "Inconclusive"; model.flows = report.flows; model.screen = .results }
                    }.fixedSize(horizontal: false, vertical: true)
                    Button(model.t("Results")) { model.flows = report.flows; model.filterStatus = "All"; model.screen = .results }.buttonStyle(.bordered)
                }
            } else { VStack { Image(systemName: "chart.bar.xaxis").font(.largeTitle); Text(model.t("No completed report yet")) }.foregroundStyle(.secondary) }
        }
    }
    func metric(_ title: String, _ value: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: icon).foregroundStyle(color); Text(value).font(.system(size: 32, weight: .bold, design: .rounded)); Text(model.t("Click to view results")).font(.caption).foregroundStyle(.secondary) }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
    }
    var resultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(model.t("Results")).font(.title.bold()); Spacer(); Button(model.t(model.compactResults ? "Show full details" : "Show compact results")) { model.compactResults.toggle() }.buttonStyle(.bordered).help(model.t(model.compactResults ? "Show full details" : "Show compact results")); Picker(model.t("Status"), selection: $model.filterStatus) { ForEach(["All","Open","Closed","Error","Inconclusive","Cancelled"], id: \.self) { Text(model.t($0)).tag($0) } }.frame(width: 150); Button(model.t("Export…")) { if let report = model.selectedReport { exportReport(report) } } }
            Table(visibleFlows) {
                TableColumn(model.t("Status")) { f in HStack { Image(systemName: icon(f.status)).foregroundStyle(color(f.status)); Text("\(model.t(f.status)) · \(f.attempts.count)/\(RetryPolicy.maximumAttempts(retriesAfterFailure: model.retryCount))") }.accessibilityLabel(model.t(f.status)) }.width(min: 110, ideal: 125)
                TableColumn(model.t("Name")) { flow in VStack(alignment: .leading) { Text(flow.name.isEmpty ? flow.host : flow.name).fontWeight(.medium); Text(model.t(flow.category.isEmpty ? "No category" : flow.category)).font(.caption).foregroundStyle(.secondary); if !flow.comment.isEmpty { Text(flow.comment).font(.caption2).foregroundStyle(.secondary).lineLimit(2) } } }.width(min: 70, ideal: 140)
                if !model.compactResults { TableColumn(model.t("Category")) { flow in Text(model.t(flow.category.isEmpty ? "No category" : flow.category)) }.width(min: 90, ideal: 125) }
                TableColumn(model.t("Host"), value: \.host).width(min: 140, ideal: 180)
                TableColumn(model.t("Port")) { Text(String($0.port)).monospacedDigit() }.width(55)
                TableColumn(model.t("Protocol"), value: \.proto).width(65)
                if !model.compactResults { TableColumn(model.t("TLS certificate")) { flow in
                    if let certificate = flow.attempts.last?.certificate {
                        Text(certificate.trusted ? model.t("Valid") : model.t("Invalid"))
                            .foregroundStyle(certificate.trusted ? .green : .red)
                            .help("\(certificate.subject) · \(certificate.issuer) · expires \(certificate.expiresAt) · SHA-256 \(certificate.sha256) · \(certificate.detail)")
                    } else { Text("—") }
                }.width(95) }
                if !model.compactResults { TableColumn(model.t("Source IP / MAC")) { flow in
                    if let attempt = flow.attempts.last {
                        VStack(alignment: .leading) {
                            Text(attempt.source.sourceIP.isEmpty ? "Unknown" : attempt.source.sourceIP)
                            Text(attempt.source.displayedMAC).font(.caption).foregroundStyle(.secondary)
                        }.help(flow.attempts.map { item in
                            "#\(item.number): IP \(item.source.sourceIP), MAC \(item.source.sourceMAC), \(item.source.interfaceName) (\(item.source.connectionType)), VPN \(item.source.vpnActive.map { $0 ? "Yes" : "No" } ?? "Unknown"), DNS \(item.source.dnsServers.joined(separator: ", "))"
                        }.joined(separator: "\n"))
                    } else { Text("—") }
                }.width(min: 110, ideal: 145) }
                if !model.compactResults { TableColumn(model.t("Link / VPN")) { flow in
                    if let attempt = flow.attempts.last {
                        let proxy = attempt.source.proxyUsed.map { model.t($0 ? "System proxy used" : "No system proxy used") } ?? model.t("Proxy use unknown")
                        Text("\(attempt.source.interfaceName) · \(attempt.source.connectionType) · VPN \(attempt.source.vpnActive.map { $0 ? "Yes" : "No" } ?? "Unknown") · \(proxy)")
                    } else { Text("—") }
                }.width(min: 130, ideal: 160) }
                TableColumn(model.t("Details")) { flow in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.t(flow.detail)).lineLimit(1)
                        Text(flow.milliseconds.map { "\($0) ms" } ?? "—").font(.caption).foregroundStyle(.secondary)
                    }.help("\(model.t(flow.detail)) · \(flow.milliseconds.map { "\($0) ms" } ?? "—")")
                }.width(min: 160, ideal: 300)
            }
        }
    }
    var visibleFlows: [Flow] { model.filterStatus == "All" ? model.flows : model.flows.filter { model.filterStatus == "Failed" ? ["Closed","Error","Inconclusive"].contains($0.status) : $0.status == model.filterStatus } }
    var reportsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.selectedReportFolderID.flatMap { id in model.reportFolders.first(where: { $0.id == id })?.name } ?? model.t("All Reports")).font(.title.bold())
                Spacer()
                Button { model.importReportsCSV() } label: { Label(model.t("Import reports…"), systemImage: "square.and.arrow.down") }
                Button { model.showingBulkDeleteConfirmation = true } label: {
                    HStack(spacing: 5) { Image(systemName: "trash"); if model.visibleSelectedReportCount > 0 { Text(String(model.visibleSelectedReportCount)) } }
                }
                .buttonStyle(.bordered).tint(.red).disabled(model.visibleSelectedReportCount == 0)
                .accessibilityLabel(model.t("Delete selected reports"))
                .help(model.t("Delete selected reports"))
                Button { model.reportFolderNameDraft = ""; model.showingNewReportFolder = true } label: { Label(model.t("New report folder"), systemImage: "folder.badge.plus") }
            }
            HStack(spacing: 10) {
                Button { model.chooseReportsFolder() } label: { Label(model.t("Choose report storage folder…"), systemImage: "folder") }
                    .help(model.t("Choose where completed reports are saved."))
                Button { model.openExportsFolder() } label: { Label(model.t("Open exports folder"), systemImage: "folder") }
                    .help(model.lastExportFolder?.path ?? model.t("Export a file first to set its folder."))
                    .disabled(model.lastExportFolder == nil)
                if let folder = model.lastExportFolder { Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Text(model.t("Reports are ordered newest first.")).font(.caption).foregroundStyle(.secondary)
            List {
                if !model.visibleReports.isEmpty {
                    Toggle(isOn: Binding(get: { model.visibleReportSelection == true }, set: { _ in model.toggleVisibleReportSelection() })) { Text(model.t("Select all reports")) }
                        .toggleStyle(.checkbox)
                        .accessibilityValue(model.t(model.visibleReportSelection == nil ? "Some reports selected" : model.visibleReportSelection == true ? "All reports selected" : "No reports selected"))
                        .accessibilityHint(model.t("Select or deselect all visible reports."))
                }
                ForEach(model.visibleReports) { report in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { model.selectedReportIDs.contains(report.id) }, set: { model.toggleReportSelection(report.id, selected: $0) })) { EmptyView() }
                            .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(model.t("Select report") + " " + report.name)
                        Button { model.selectReport(report) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(report.name).font(.headline)
                                        if report.imported != nil { Label(model.t("Imported"), systemImage: "square.and.arrow.down").font(.caption).padding(.horizontal, 6).padding(.vertical, 3).background(.blue.opacity(0.12), in: Capsule()) }
                                    }
                                    if let origin = report.imported, let computer = origin.computer, !computer.isEmpty { Text(computer).font(.caption) }
                                    Text(DateFormatter.reportDate.string(from: report.createdAt)).font(.caption).foregroundStyle(.secondary)
                                    Label(model.reportFolderName(for: report), systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(report.flows.count) · \(model.t("Failed")): \(report.failures)").font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .overlay { if model.visibleReports.isEmpty { VStack { Image(systemName: "tray"); Text(model.t("No completed report yet")) }.foregroundStyle(.secondary) } }
        }
    }
    var footer: some View {
        VStack(alignment: .leading) {
        HStack {
            Text("\(model.flows.count) \(model.t("flows")) · \(model.flows.filter { $0.status == "Open" }.count) \(model.t("confirmed"))").foregroundStyle(.secondary)
            Spacer()
            Text(model.t("Saved automatically") + " · " + model.reportFolder.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            if model.screen == .templates { Button(model.t("Run tests")) { model.requestRun() }.disabled(model.running || model.flows.filter(\.selected).isEmpty) }
        }
        Text(model.t("TCP checks connectivity, not TLS or application health. UDP requires a response; silence is inconclusive.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    func exportReport(_ report: SavedReport) {
        model.selectedReportID = report.id; model.exportName = report.name; model.exportFormat = .csv
        model.showExport = true
    }
    func icon(_ status: String) -> String { if status.hasPrefix("Retrying") { return "arrow.clockwise" }; switch status { case "Open": return "checkmark.square.fill"; case "Closed", "Error": return "xmark.square.fill"; case "Inconclusive": return "questionmark.square.fill"; case "Running": return "arrow.triangle.2.circlepath"; default: return "square" } }
    func color(_ status: String) -> Color { if status.hasPrefix("Retrying") { return .blue }; switch status { case "Open": return .green; case "Closed", "Error": return .red; case "Inconclusive": return .orange; case "Running": return .blue; default: return .secondary } }
}

extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var pretty: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension DateFormatter {
    static let reportDate: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    static let reportName: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; return f }()
}
@MainActor final class EmailRecipientSheetState: ObservableObject {
    @Published var showingEditor = false
    @Published var editingID: UUID?
    @Published var draftName = ""
    @Published var draftAddress = ""
    @Published var draftComment = ""
    @Published var formError: String?
    @Published var deleteTarget: EmailRecipient?
}

@MainActor private final class TemporaryReportEmailDelegate: NSObject, NSSharingServiceDelegate {
    static let shared = TemporaryReportEmailDelegate()

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        cleanup(items)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        cleanup(items)
    }

    private func cleanup(_ items: [Any]) {
        for url in items.compactMap({ $0 as? URL }) {
            TemporaryReportEmailFiles.removeSharedFileFolder(for: url)
        }
    }
}

struct EmailRecipientsSheet: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = EmailRecipientSheetState()

    var body: some View {
        Group {
            if state.showingEditor { editor }
            else { recipientPicker }
        }
        .padding(22)
        .frame(width: 560, height: 500)
        .confirmationDialog(model.t("Delete recipient?"), isPresented: Binding(get: { state.deleteTarget != nil }, set: { if !$0 { state.deleteTarget = nil } }), titleVisibility: .visible) {
            Button(model.t("Delete recipient"), role: .destructive) {
                if let recipient = state.deleteTarget { model.deleteEmailRecipient(recipient.id) }
                state.deleteTarget = nil
            }
            Button(model.t("Cancel"), role: .cancel) { state.deleteTarget = nil }
        }
    }

    private var recipientPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.t("Email report")).font(.title2.bold())
                    Spacer()
                    Button { startAdding() } label: { Label(model.t("Add recipient"), systemImage: "plus") }
                }
                Text(model.t("Select recipients for this report. Comments are private notes and are not included in the email."))
                    .font(.caption).foregroundStyle(.secondary)
                Label(model.t("Review report before sharing"), systemImage: "exclamationmark.shield.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Text(model.t("The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending.")).font(.caption).foregroundStyle(.secondary)
            }
            if model.emailRecipients.isEmpty {
                ContentUnavailableView(model.t("No email recipients saved"), systemImage: "person.crop.circle.badge.plus", description: Text(model.t("Add an email address to prepare a report email.")))
            } else {
                List(model.emailRecipients) { recipient in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.emailRecipientSelection.contains(recipient.id) }, set: { model.toggleEmailRecipient(recipient.id, selected: $0) })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recipient.name.isEmpty ? recipient.emailAddress : recipient.name).fontWeight(.medium)
                                if !recipient.name.isEmpty { Text(recipient.emailAddress).font(.caption).foregroundStyle(.secondary) }
                                if !recipient.comment.isEmpty { Text(recipient.comment).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(recipient.name.isEmpty ? recipient.emailAddress : recipient.name), \(recipient.emailAddress)")
                        Button { startEditing(recipient) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help(model.t("Edit recipient"))
                        Button(role: .destructive) { state.deleteTarget = recipient } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(model.t("Delete recipient"))
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            HStack {
                Text("\(model.emailRecipientSelection.count) · \(model.t("Selected"))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.t("Cancel")) { dismiss() }
                Button(model.t("Prepare email")) { if model.emailSelectedReport() { dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(model.emailRecipientSelection.isEmpty)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t(state.editingID == nil ? "Add recipient" : "Edit recipient")).font(.title2.bold())
            Form {
                TextField(model.t("Recipient name (optional)"), text: $state.draftName)
                TextField(model.t("Email address"), text: $state.draftAddress).textContentType(.emailAddress).autocorrectionDisabled()
                TextField(model.t("Comment (optional)"), text: $state.draftComment, axis: .vertical).lineLimit(3...6)
            }
            if let formError = state.formError { Text(model.t(formError)).font(.caption).foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                Button(model.t("Cancel")) { state.showingEditor = false; state.formError = nil }
                Button(model.t("Save recipient")) { saveDraft() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func startAdding() {
        state.editingID = nil; state.draftName = ""; state.draftAddress = ""; state.draftComment = ""; state.formError = nil; state.showingEditor = true
    }
    private func startEditing(_ recipient: EmailRecipient) {
        state.editingID = recipient.id; state.draftName = recipient.name; state.draftAddress = recipient.emailAddress; state.draftComment = recipient.comment; state.formError = nil; state.showingEditor = true
    }
    private func saveDraft() {
        let recipient = EmailRecipient(id: state.editingID ?? UUID(), name: state.draftName, emailAddress: state.draftAddress, comment: state.draftComment)
        guard EmailRecipient.isValidAddress(recipient.emailAddress) else { state.formError = "Enter a valid email address."; return }
        guard !model.emailRecipients.contains(where: { $0.id != recipient.id && $0.emailAddress.caseInsensitiveCompare(recipient.emailAddress) == .orderedSame }) else {
            state.formError = "A recipient with this email address already exists."; return
        }
        if model.saveEmailRecipient(recipient) { state.showingEditor = false; state.formError = nil }
        else { state.formError = model.message }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 16) {
        Text(model.t("Export…")).font(.title2.bold())
        TextField(model.t("Report name"), text: $model.exportName)
        Picker(model.t("Export format"), selection: $model.exportFormat) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
        HStack { Spacer(); Button(model.t("Cancel")) { dismiss() }; Button(model.t("Save")) { model.exportSelected(); dismiss() }.buttonStyle(.borderedProminent) }
    }.padding(24).frame(width: 360) }
}

struct CategoryManagerSheet: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("Manage categories")).font(.title2.bold())
            HStack { TextField(model.t("Category name"), text: $model.categoryNewName); Button(model.t("Add category")) { model.createCategory(model.categoryNewName); model.categoryNewName = "" }.disabled(model.categoryNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            List {
                ForEach(model.currentCategories, id: \.self) { category in
                    HStack {
                        if model.categoryRenameTarget == category {
                            TextField(model.t("Category name"), text: $model.categoryRenameName)
                            Button(model.t("Save")) { model.renameCategory(category, to: model.categoryRenameName); model.categoryRenameTarget = nil }
                            Button(model.t("Cancel")) { model.categoryRenameTarget = nil }
                        } else {
                            Text(model.t(category)); Spacer()
                            Button { model.categoryRenameName = category; model.categoryRenameTarget = category } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).disabled(category == "General").help(model.t("Rename category"))
                            Button(role: .destructive) { model.categoryDeleteTarget = category } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(category == "General").help(model.t("Delete category"))
                        }
                    }
                }
            }.frame(minHeight: 250)
            HStack { Spacer(); Button(model.t("Close")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 480, height: 440)
            .confirmationDialog(model.t("Delete category?"), isPresented: Binding(get: { model.categoryDeleteTarget != nil }, set: { if !$0 { model.categoryDeleteTarget = nil } }), titleVisibility: .visible) {
                Button(model.t("Delete category"), role: .destructive) { if let deleting = model.categoryDeleteTarget { model.removeCategory(deleting) }; model.categoryDeleteTarget = nil }
                Button(model.t("Cancel"), role: .cancel) { model.categoryDeleteTarget = nil }
            } message: { Text(model.t("Flows in this category move to General.")) }
    }
}

struct CategorySelectionHeader: View {
    @EnvironmentObject private var model: Model
    let category: String
    let selection: Bool?
    let isCollapsed: Bool
    private var symbol: String { selection == nil ? "minus.square.fill" : selection == true ? "checkmark.square.fill" : "square" }
    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggleCategoryCollapsed(category) } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.t(isCollapsed ? "Expand category" : "Collapse category") + " \(model.t(category))")
            .help(model.t(isCollapsed ? "Show flows in this category" : "Hide flows in this category"))
            Button { model.setCategorySelection(category, selection != true) } label: {
                Image(systemName: symbol).foregroundColor(selection == false ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.t("Include all tests in category") + " \(model.t(category))")
            .help(model.t("Select or clear every test in this category."))
            .disabled(model.running || model.finalizing || model.flows.filter { $0.category == category }.isEmpty)
            Text(model.t(category.isEmpty ? "No category" : category))
            if selection == nil { Text(model.t("Mixed selection")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FlowEditorSheet: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t(model.editingFlowID == nil ? "Add flow" : "Edit flow")).font(.title2.bold())
            Form {
                TextField(model.t("Name"), text: $model.flowEditorName)
                TextField(model.t("Hostname, URL, or IP address"), text: $model.flowEditorHost)
                TextField(model.t("Port"), text: $model.flowEditorPort)
                TextField(model.t("Comment"), text: $model.flowEditorComment, axis: .vertical).lineLimit(2...4)
                Text(model.t("Optional explanation of what this network flow is used for.")).font(.caption).foregroundStyle(.secondary)
                Picker(model.t("Protocol"), selection: $model.flowEditorProtocol) { ForEach(["TCP", "UDP", "HTTPS"], id: \.self) { Text($0).tag($0) } }
                Picker(model.t("Category"), selection: $model.flowEditorCategory) {
                    Text(model.t("No category")).tag("")
                    ForEach(model.currentCategories, id: \.self) { Text(model.t($0)).tag($0) }
                }
                if model.flowEditorProtocol == "UDP" {
                    TextField(model.t("UDP payload (hex, optional)"), text: $model.flowEditorPayload)
                    Text(model.t("Optional UDP request bytes in hexadecimal. Leave blank for a generic probe; some services require a specific request.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Button(model.t("Manage categories")) { model.showingFlowEditor = false; model.showingCategoryManager = true }; Spacer(); Button(model.t("Cancel")) { dismiss() }; Button(model.t("Save")) { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 480)
    }
    private func save() {
        guard let portNumber = UInt16(model.flowEditorPort), portNumber > 0 else { model.message = "Enter a valid host and port."; return }
        let normalizedHost: String
        do { normalizedHost = try DestinationInputValidator.normalize(model.flowEditorHost, port: portNumber) }
        catch { model.message = error.localizedDescription; return }
        guard model.flowEditorPayload.isEmpty || (model.flowEditorProtocol == "UDP" && CSV.hex(model.flowEditorPayload) != nil) else { model.message = "UDP payload must be valid hexadecimal data."; return }
        let category = model.flowEditorCategory == "General" ? DestinationClassifier.category(for: normalizedHost) : model.flowEditorCategory
        let flow = Flow(id: model.editingFlowID ?? UUID(), name: model.flowEditorName.trimmingCharacters(in: .whitespacesAndNewlines), host: normalizedHost, port: portNumber, proto: model.flowEditorProtocol, payload: model.flowEditorProtocol == "UDP" ? model.flowEditorPayload : "", category: category, comment: model.flowEditorComment)
        if model.saveFlow(flow) { dismiss() }
    }
}

struct HelpContactSheet: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.t("NetworkPortEval Help"), systemImage: "network").font(.title2.bold())
            Text(model.t("Import a CSV template, select the tests to run, then press Play."))
            Text(model.t("TCP checks connectivity, not TLS or application health. UDP requires a response; silence is inconclusive."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.t("HTTPS checks certificate trust and hostname; it sends HEAD /."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.t("The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.t("Saved reports are stored locally and are not encrypted by the app."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.t("Open Overview or Results to review a completed report. Reports are saved automatically and can be exported from File → Export."))
            Text(model.t("Only test network destinations you are authorized to assess.")).foregroundStyle(.secondary)
            Divider()
            LabeledContent(model.t("Publisher"), value: "BC performances")
            LabeledContent(model.t("Author"), value: "Baptiste CRESTANI")
            HStack { Text(model.t("Contact")); Spacer(); Link("bcperf@gmail.com", destination: URL(string: "mailto:bcperf@gmail.com")!) }
            HStack { Text(model.t("Privacy policy")); Spacer(); Link("bat73300.github.io/NetworkPortEval/privacy/", destination: URL(string: "https://bat73300.github.io/NetworkPortEval/privacy/")!) }
            HStack { Spacer(); Button(model.t("Close")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct FileCommands: Commands {
    @ObservedObject var model: Model
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(model.t("Export…")) { model.beginExportSelectedReport() }.keyboardShortcut("e", modifiers: [.command]).disabled(model.selectedReport == nil)
            Button(model.t("Rename")) { model.draftName = model.selectedReport?.name ?? ""; model.renameReportPrompt = true }.disabled(model.selectedReport == nil)
            Button(model.t("Delete"), role: .destructive) { model.deleteTarget = model.selectedReport }.disabled(model.selectedReport == nil)
        }
        CommandMenu(model.t("Reports")) {
            Button(model.t("Choose a reports folder")) { model.chooseReportsFolder() }
            Button(model.t("Use standard folder")) { model.standardReportsFolder() }
        }
    }
}
@main struct NetworkPortEvalApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup(id: "main") { ContentView().environmentObject(model) }
        .commands {
            FileCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                Button(model.t("About NetworkPortEval")) { showAboutPanel() }
            }
            CommandGroup(replacing: .help) {
                Button(model.t("Help & Contact")) { model.showingHelp = true }
            }
        }
        MenuBarExtra {
            ScheduleMenuView().environmentObject(model)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "network").symbolRenderingMode(.monochrome).font(.system(size: 16, weight: .regular))
                if model.hasScheduledProgram {
                    Circle().fill(Color.red).frame(width: 7, height: 7).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)).offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel(model.hasScheduledProgram ? model.t("Automatic schedule active") : "NetworkPortEval")
        }
        .menuBarExtraStyle(.menu)
    }
    private func showAboutPanel() {
        let credits = NSAttributedString(string: "\(model.t("Publisher")): BC performances\n\(model.t("Author")): Baptiste CRESTANI\n\(model.t("Contact")): bcperf@gmail.com\nCopyright © 2026 BC performances")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NetworkPortEval",
            .applicationVersion: "0.1.0",
            .version: "1",
            .credits: credits
        ])
    }
}
struct ScheduleMenuView: View {
    @EnvironmentObject private var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.hasScheduledProgram {
            Text(model.t("Automatic schedule active")).font(.headline)
            ForEach(model.scheduledTests.filter(\.isEnabled).prefix(8)) { item in
                Text("\(model.scheduledTemplateName(item)) · \(model.t("Interval:")) \(model.scheduleIntervalText(item)) · \(model.t((item.includeInternetChecks ?? true) ? "Public checks on" : "Public checks off"))")
            }
            if let nextRun = model.nextScheduledRun { Text("\(model.t("Next run:")) \(DateFormatter.reportDate.string(from: nextRun))") }
        } else {
            Text(model.t("No automatic test scheduled"))
        }
        Divider()
        Button(model.t("Open schedule settings…")) {
            model.screen = .schedules
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }
}
struct ScheduledTestEditorSheet: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t(model.editingScheduledTestID == nil ? "New schedule" : "Edit schedule")).font(.title2.bold())
            Form {
                Picker(model.t("Template"), selection: $model.scheduleTemplateDraft) {
                    ForEach(model.templates) { template in Text(template.name).tag(Optional(template.id)) }
                }
                HStack {
                    Text(model.t("Run every"))
                    Stepper(value: $model.scheduleCountDraft, in: 1...60) { Text("\(model.scheduleCountDraft)").frame(minWidth: 28) }
                    Picker(model.t("Interval unit"), selection: $model.scheduleUnitDraft) {
                        ForEach(ScheduleUnit.allCases, id: \.self) { unit in Text(model.t(unit.rawValue)).tag(unit) }
                    }.labelsHidden().frame(width: 130)
                }
            }
            Text(model.t("The schedule runs while NetworkPortEval is open. The first run starts after the selected interval."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(model.t("Include public Internet checks"), isOn: $model.scheduleIncludesInternetChecks)
                .toggleStyle(.switch)
            Text(model.t("When enabled, scheduled reports contact Google, Apple and api.ipify.org; api.ipify.org returns your public IP. Turn this off to omit these app-added checks from every scheduled run."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.t("Only run tests on destinations you are authorized to test."))
                .font(.caption).foregroundStyle(.secondary)
            if let warning = model.largeRunWarning(for: model.scheduleTemplateSelectedFlowCount) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.scheduleTemplateHasSelectedFlows {
                Text(model.t("Select at least one test in the selected template before scheduling."))
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            HStack { Spacer(); Button(model.t("Cancel")) { dismiss() }; Button(model.t("Save")) { if model.saveScheduledTest() { dismiss() } }.buttonStyle(.borderedProminent).disabled(model.templates.isEmpty || model.scheduleTemplateDraft == nil || !model.scheduleTemplateHasSelectedFlows) }
        }.padding(24).frame(width: 500)
    }
}
struct RenameSheet: View {
    @EnvironmentObject var model: Model; @Environment(\.dismiss) var dismiss
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text(model.t("Rename")).font(.title2.bold()); TextField(model.t("Report name"), text: $model.draftName); HStack { Spacer(); Button(model.t("Cancel")) { dismiss() }; Button(model.t("Save")) { model.renameSelectedReport(); dismiss() }.buttonStyle(.borderedProminent) } }.padding(24).frame(width: 360) }
}
