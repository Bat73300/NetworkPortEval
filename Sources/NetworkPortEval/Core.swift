import Foundation
import Network
import Darwin
import Security
import CryptoKit

struct FlowTemplate: Identifiable, Codable, Hashable {
    var id = UUID(); var name: String; var flows: [Flow]; var categories: [String]
    init(id: UUID = UUID(), name: String, flows: [Flow], categories: [String]? = nil) {
        self.id = id; self.name = name; self.flows = flows
        self.categories = Array(Set(((categories ?? flows.map(\.category)) + ["General"]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    enum CodingKeys: String, CodingKey { case id, name, flows, categories }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFlows = try values.decode([Flow].self, forKey: .flows)
        self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), name: try values.decode(String.self, forKey: .name), flows: decodedFlows, categories: try values.decodeIfPresent([String].self, forKey: .categories))
    }
}

enum BlankTemplate {
    static func make(name rawName: String, existing: [FlowTemplate]) throws -> FlowTemplate {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CSV.error("Enter a template name.") }
        guard name.count <= 100 else { throw CSV.error("Template names are limited to 100 characters.") }
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw CSV.error("A template with this name already exists.")
        }
        return FlowTemplate(name: name, flows: [], categories: ["General"])
    }
}

enum AppDataStore {
    // Current files use ISO 8601; accept older Foundation numeric dates too.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid stored date: \(text)")
        }
        return decoder
    }

    static func writePrivate(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try data.write(to: url, options: .atomic)
        try restrictPermissions(at: url, fileManager: fileManager)
    }

    static func restrictPermissions(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func copyMissingItems(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let sourceIsDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var targetIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) {
                if sourceIsDirectory && targetIsDirectory.boolValue {
                    try copyMissingItems(from: item, to: target, fileManager: fileManager)
                }
                continue
            }
            try fileManager.copyItem(at: item, to: target)
        }
    }
}

enum TemporaryReportEmailFiles {
    static let directoryPrefix = "NetworkPortEval-"
    static let staleAge: TimeInterval = 30 * 24 * 60 * 60

    static func removeSharedFileFolder(for fileURL: URL, in temporaryRoot: URL = FileManager.default.temporaryDirectory, fileManager: FileManager = .default) {
        let root = temporaryRoot.standardizedFileURL
        let file = fileURL.standardizedFileURL
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == root,
              folder.lastPathComponent.hasPrefix(directoryPrefix),
              let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? fileManager.removeItem(at: folder)
    }

    static func cleanupStaleDirectories(in temporaryRoot: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = staleAge, now: Date = Date(), fileManager: FileManager = .default) {
        let root = temporaryRoot.standardizedFileURL
        guard let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for item in items {
            guard item.deletingLastPathComponent().standardizedFileURL == root,
                  item.lastPathComponent.hasPrefix(directoryPrefix),
                  let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= age else { continue }
            try? fileManager.removeItem(at: item)
        }
    }
}

enum VisibleItemSelection {
    static func state(visibleIDs: Set<UUID>, selectedIDs: Set<UUID>) -> Bool? {
        guard !visibleIDs.isEmpty else { return false }
        let selectedVisibleIDs = visibleIDs.intersection(selectedIDs)
        return selectedVisibleIDs.isEmpty ? false : selectedVisibleIDs.count == visibleIDs.count ? true : nil
    }

    static func toggleAll(visibleIDs: Set<UUID>, selectedIDs: Set<UUID>) -> Set<UUID> {
        guard !visibleIDs.isEmpty else { return selectedIDs }
        if visibleIDs.isSubset(of: selectedIDs) { return selectedIDs.subtracting(visibleIDs) }
        return selectedIDs.union(visibleIDs)
    }

    static func selectedVisibleIDs(visibleIDs: Set<UUID>, selectedIDs: Set<UUID>) -> Set<UUID> {
        visibleIDs.intersection(selectedIDs)
    }
}

enum CSVImportFeedback {
    static func duplicatePreview(_ destinations: [String], limit: Int = 10) -> String {
        let safeLimit = max(0, limit)
        let examples = destinations.prefix(safeLimit)
        let preview = examples.joined(separator: ", ")
        let remaining = destinations.count - examples.count
        guard remaining > 0 else { return preview }
        return preview.isEmpty ? "… (+\(remaining))" : "\(preview), … (+\(remaining))"
    }
}

struct SourceInfo: Codable, Hashable {
    var sourceIP = ""
    var sourceMAC = ""
    var interfaceName = ""
    var physicalInterfaceName = ""
    var connectionType = "Unknown"
    var vpnActive: Bool? = nil
    var dnsServers: [String] = []
    var proxyConfigured: Bool? = nil
    var proxyUsed: Bool? = nil
    var displayedMAC: String { sourceMAC.isEmpty ? "Unavailable" : sourceMAC }
}
struct ProbeAttempt: Identifiable, Codable, Hashable {
    var id = UUID()
    var number: Int
    var status: String
    var detail: String
    var milliseconds: Int?
    var testedAt: String
    var source = SourceInfo()
    var certificate: CertificateSummary? = nil
}
struct CertificateSummary: Codable, Hashable {
    var host: String
    var subject: String
    var issuer: String
    var sha256: String
    var expiresAt: String
    var trusted: Bool
    var detail: String
}
struct InternetCheck: Codable, Hashable {
    var service: String
    var result: String
    var httpStatus: Int?
    var detail: String
    var source = SourceInfo()
    var certificate: CertificateSummary? = nil
}
struct Flow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var proto: String
    var payload: String = ""
    var comment: String = ""
    var category = "General"
    var status = "Pending"
    var detail = ""
    var milliseconds: Int? = nil
    var testedAt = ""
    var selected = true
    var attempts: [ProbeAttempt] = []

    init(id: UUID = UUID(), name: String, host: String, port: UInt16, proto: String, payload: String = "", category: String = "General", comment: String = "") {
        self.id = id; self.name = name; self.host = host; self.port = port; self.proto = proto; self.payload = payload; self.category = category; self.comment = comment
    }
    enum CodingKeys: String, CodingKey { case id, name, host, port, proto, payload, category, comment, status, detail, milliseconds, testedAt, selected, attempts }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(UInt16.self, forKey: .port)
        proto = try values.decode(String.self, forKey: .proto)
        payload = try values.decodeIfPresent(String.self, forKey: .payload) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? "General"
        comment = try values.decodeIfPresent(String.self, forKey: .comment) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "Pending"
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        milliseconds = try values.decodeIfPresent(Int.self, forKey: .milliseconds)
        testedAt = try values.decodeIfPresent(String.self, forKey: .testedAt) ?? ""
        selected = try values.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        attempts = try values.decodeIfPresent([ProbeAttempt].self, forKey: .attempts) ?? []
    }
}

enum DefaultNetworkChecks {
    static let flows = [
        Flow(name: "Google HTTPS", host: "www.google.com", port: 443, proto: "HTTPS", category: "Web", comment: "Public HTTPS and TLS certificate check."),
        Flow(name: "Apple HTTPS", host: "www.apple.com", port: 443, proto: "HTTPS", category: "Web", comment: "Public HTTPS and TLS certificate check."),
        Flow(name: "Cloudflare HTTPS", host: "www.cloudflare.com", port: 443, proto: "HTTPS", category: "Web", comment: "Public HTTPS and TLS certificate check."),
        Flow(name: "GitHub HTTPS", host: "github.com", port: 443, proto: "HTTPS", category: "Web", comment: "Public HTTPS and TLS certificate check."),
        Flow(name: "Wikipedia HTTPS", host: "www.wikipedia.org", port: 443, proto: "HTTPS", category: "Web", comment: "Public HTTPS and TLS certificate check.")
    ]
}
struct TemplateBootstrapResult {
    let templates: [FlowTemplate]
    let seededDefaults: Bool
}
enum TemplateBootstrap {
    static func load(_ data: Data?) -> TemplateBootstrapResult {
        if let data, let decoded = try? AppDataStore.decoder.decode([FlowTemplate].self, from: data), !decoded.isEmpty {
            return TemplateBootstrapResult(templates: decoded, seededDefaults: false)
        }
        return TemplateBootstrapResult(
            templates: [FlowTemplate(name: "Public network checks", flows: DefaultNetworkChecks.flows, categories: ["General", "Web"])],
            seededDefaults: true
        )
    }
}

struct EmailRecipient: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var emailAddress: String
    var comment: String

    init(id: UUID = UUID(), name: String = "", emailAddress: String, comment: String = "") {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 254, !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        let pattern = #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$"#
        return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum FlowCategories {
    static func canonicalName(for category: String, existing: [String]) -> String {
        let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) ?? value
    }
    static func additions(existing: [String], flows: [Flow]) -> [String] {
        var known = Set(existing.map { $0.lowercased() })
        var result: [String] = []
        for flow in flows {
            let value = flow.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, known.insert(value.lowercased()).inserted else { continue }
            result.append(value)
        }
        return result
    }
    static func merged(existing: [String], flows: [Flow]) -> [String] {
        let values = existing.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + additions(existing: existing, flows: flows)
        let categories = values.isEmpty ? ["General"] : values
        return categories.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum DestinationInputValidator {
    static func normalize(_ rawValue: String, port: UInt16) throws -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 2_048, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CSV.error("Destination must be non-empty and no longer than 2,048 bytes.")
        }
        var host = raw
        if raw.contains("://") {
            guard let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let parsedHost = components.host, !parsedHost.isEmpty,
                  components.user == nil, components.password == nil, components.fragment == nil,
                  components.port.map({ $0 == Int(port) }) ?? true else {
                throw CSV.error("URL must use http or https, contain no credentials or fragment, and use the same port as the port column.")
            }
            host = parsedHost
        }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { throw CSV.error("IPv6 addresses must use matching brackets.") }
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains(where: { "/?#@%".contains($0) }) else {
            throw CSV.error("Invalid destination host.")
        }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return host }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return host.lowercased() }
        guard !host.contains(":"), !host.isEmpty else { throw CSV.error("Invalid IP address or hostname.") }

        // URLComponents performs Foundation's IDNA host conversion, yielding an ASCII A-label for Unicode DNS names.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let asciiHost = components.url?.host?.lowercased() else { throw CSV.error("Invalid hostname or internationalized domain name.") }
        let withoutRootDot = asciiHost.hasSuffix(".") ? String(asciiHost.dropLast()) : asciiHost
        guard !withoutRootDot.isEmpty, withoutRootDot.utf8.count <= 253 else { throw CSV.error("Hostname must be no longer than 253 bytes.") }
        let labels = withoutRootDot.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.first, let last = label.last,
                  first.isASCII && last.isASCII,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { throw CSV.error("Hostname contains an invalid DNS label.") }
        if labels.count > 1, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            throw CSV.error("A dotted numeric host must be a valid IPv4 address.")
        }
        return withoutRootDot
    }
}

enum FlowInputValidator {
    static func normalize(_ flow: Flow) throws -> Flow {
        guard flow.port > 0 else { throw CSV.error("Port must be between 1 and 65535.") }
        var value = flow
        value.host = try DestinationInputValidator.normalize(flow.host, port: flow.port)
        value.proto = flow.proto.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["TCP", "UDP", "HTTPS"].contains(value.proto) else { throw CSV.error("Protocol must be TCP, UDP or HTTPS.") }
        value.name = flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.category = flow.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.name.utf8.count <= 128, value.category.utf8.count <= 128 else { throw CSV.error("Flow name and category must be no longer than 128 bytes each.") }
        value.comment = flow.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.comment.utf8.count <= 2_000 else { throw CSV.error("Flow comment must be no longer than 2,000 bytes.") }
        guard flow.payload.isEmpty || (value.proto == "UDP" && CSV.hex(flow.payload) != nil) else { throw CSV.error("UDP payload must be valid hexadecimal data of at most 1,200 bytes.") }
        value.payload = value.proto == "UDP" ? flow.payload : ""
        return value
    }
}

enum CSV {
    static func records(_ text: String) throws -> [[String]] {
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let first = clean.components(separatedBy: .newlines).first ?? ""
        let delimiter: Character = first.contains(";") ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(clean); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == delimiter && !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r") && !quoted {
                row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; field = ""
                if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw error("Unclosed quote in CSV.") }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
    static func parse(_ text: String) throws -> [Flow] {
        let rows = try records(text)
        guard let header = rows.first else { throw error("CSV is empty.") }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let hostIndex = keys.firstIndex(where: { ["host", "hostname", "host name", "url", "ip", "ip address", "destination", "hote", "hôte"].contains($0) }), let portIndex = keys.firstIndex(of: "port") else { throw error("Required headers: host/hostname/url/IP address and port. Optional protocol column (TCP by default).") }
        guard rows.count <= 10001 else { throw error("Maximum: 10,000 flows per import.") }
        return try rows.dropFirst().enumerated().map { offset, values in
            func value(_ index: Int?) -> String { guard let index, index < values.count else { return "" }; return values[index].trimmingCharacters(in: .whitespacesAndNewlines) }
            let raw = value(hostIndex)
            guard let port = UInt16(value(portIndex)), port > 0 else { throw error("Row \(offset+2): Invalid port (1–65535).") }
            let p = value(keys.firstIndex(where: { ["protocol", "protocole"].contains($0) })).uppercased()
            guard p.isEmpty || ["TCP", "UDP", "HTTPS"].contains(p) else { throw error("Row \(offset+2): Expected TCP, UDP or HTTPS.") }
            let payload = value(keys.firstIndex(of: "payload_hex"))
            let categoryIndex = keys.firstIndex(where: { ["category", "categorie", "catégorie"].contains($0) })
            let category = value(categoryIndex)
            let comment = value(keys.firstIndex(where: { ["comment", "commentary", "commentaire", "notes"].contains($0) }))
            let host: String
            do { host = try DestinationInputValidator.normalize(raw, port: port) }
            catch let validationError { throw error("Row \(offset+2): \(validationError.localizedDescription)") }
            let name = value(keys.firstIndex(where: { ["name", "nom"].contains($0) }))
            guard name.utf8.count <= 128, category.utf8.count <= 128, comment.utf8.count <= 2_000 else { throw error("Row \(offset+2): name/category must be no longer than 128 bytes and comment no longer than 2,000 bytes.") }
            guard payload.isEmpty || (p == "UDP" && hex(payload) != nil) else { throw error("Row \(offset+2): payload_hex is allowed only for UDP and must contain at most 1200 valid bytes.") }
            // A blank category column explicitly means “No category”. If the CSV
            // has no category column at all, retain the destination auto-classifier.
            let resolvedCategory = categoryIndex == nil ? DestinationClassifier.category(for: host) : category
            var flow = Flow(name: name, host: host, port: port, proto: p.isEmpty ? "TCP" : p, payload: payload, category: resolvedCategory, comment: comment)
            flow.selected = false
            return flow
        }
    }
    static func error(_ message: String) -> NSError { NSError(domain: "NetworkPortEval", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func destinationKey(host: String, port: UInt16) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = trimmed.contains("://") ? (URLComponents(string: trimmed)?.host ?? trimmed) : trimmed
        let normalized = extracted.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return "\(normalized):\(port)"
    }
    static func hex(_ string: String) -> Data? {
        let chars = Array(string.filter { !$0.isWhitespace }); guard chars.count % 2 == 0, chars.count <= 2400 else { return nil }
        var data = Data(); for i in stride(from: 0, to: chars.count, by: 2) { guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }; data.append(b) }; return data
    }
    static func templateCSV(_ flows: [Flow]) -> String {
        let header = ["name", "comment", "category", "host", "port", "protocol", "payload_hex"]
        let rows = flows.map { [$0.name, $0.comment, $0.category, $0.host, String($0.port), $0.proto, $0.payload] }
        return "\u{FEFF}" + header.map(spreadsheetCell).joined(separator: ";") + "\r\n" + rows.map { $0.map(spreadsheetCell).joined(separator: ";") }.joined(separator: "\r\n") + (rows.isEmpty ? "" : "\r\n")
    }
    static func blankTemplateCSV() -> String {
        templateCSV([])
    }
    private static func spreadsheetCell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+-@".contains($0) } == true || value.hasPrefix("\t") || value.hasPrefix("\r") ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func export(_ flows: [Flow], reportName: String? = nil, createdAt: Date? = nil, publicIP: String? = nil, internetStatus: String? = nil, internetChecks: [InternetCheck] = [], translate: (String) -> String = { $0 }, reportID: UUID? = nil, sourceMetadata: [String: String] = [:]) -> String {
        func cell(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true || value.hasPrefix("\t") || value.hasPrefix("\r") ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let checkSummary = internetChecks.map { check in
            let certificate = check.certificate.map { "TLS \($0.trusted ? translate("valid") : translate("invalid")) \(translate("for")) \($0.host),  \(translate("subject")) \($0.subject),  \(translate("issuer")) \($0.issuer),  \(translate("expires")) \($0.expiresAt), SHA-256 \($0.sha256)" } ?? translate("TLS certificate unavailable")
            return "\(check.service): \(check.result)\(check.httpStatus.map { " (HTTP \($0))" } ?? "") — \(check.detail); \(certificate)"
        }.joined(separator: " | ")
        let network = ReportNetworkHeader(flows: flows, internetChecks: internetChecks)
        var metadata: [[String]] = [
            ["Report", "NetworkPortEval"],
            ["Report name", reportName ?? ""],
            ["Created at", createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""],
            ["Public IP", publicIP ?? "Unavailable"],
            ["Internet status", internetStatus ?? "Not checked"],
            ["Internet checks", checkSummary.isEmpty ? "Not available" : checkSummary],
            ["Source IP address(es)", network.sourceIPs],
            ["Local MAC address(es)", network.sourceMACs],
            ["Route interface(s)", network.interfaces],
            ["Physical interface(s)", network.physicalInterfaces],
            ["Connection type(s)", network.connectionTypes],
            ["VPN active", network.vpnStates],
            ["System proxy used", network.proxyStates ?? "Unknown"],
            ["Configured DNS server(s)", network.dnsServers]
        ]
        metadata = metadata.map { row in
            guard !["Report", "Report name", "Created at"].contains(row[0]), let original = sourceMetadata[row[0]] else { return row }
            return [row[0], original]
        }
        if let reportID { metadata += [["Report ID", reportID.uuidString], ["Format version", "1"]] }
        let header = ["category","name","comment","host","port","protocol","payload_hex","status","detail","latency_ms","tested_at","attempt","tls_host","tls_subject","tls_issuer","tls_sha256","tls_expires_at","tls_trusted"]
        let rows = flows.flatMap { flow -> [[String]] in
            guard !flow.attempts.isEmpty else {
                var row = Array(repeating: "", count: header.count)
                row[0] = flow.category; row[1] = flow.name; row[2] = flow.comment; row[3] = flow.host; row[4] = String(flow.port); row[5] = flow.proto; row[6] = flow.payload
                row[7] = flow.status; row[8] = flow.detail; row[9] = flow.milliseconds.map(String.init) ?? ""; row[10] = flow.testedAt
                row[17] = translate("Not applicable")
                return [row]
            }
            return flow.attempts.map { attempt in
                [flow.category,flow.name,flow.comment,flow.host,String(flow.port),flow.proto,flow.payload,attempt.status,attempt.detail,attempt.milliseconds.map(String.init) ?? "",attempt.testedAt,String(attempt.number),attempt.certificate?.host ?? "",attempt.certificate?.subject ?? "",attempt.certificate?.issuer ?? "",attempt.certificate?.sha256 ?? "",attempt.certificate?.expiresAt ?? "",attempt.certificate.map { $0.trusted ? translate("Yes") : translate("No") } ?? translate("Not applicable")]
            }
        }
        let localizedMetadata = metadata.map { [translate($0[0]), $0[1].components(separatedBy: "; ").map(translate).joined(separator: "; ")] }
        let csvRows = localizedMetadata + [[""]] + [header] + rows
        return "\u{FEFF}" + csvRows.map { $0.map(cell).joined(separator: ";") }.joined(separator: "\r\n")
    }
}

struct ReportNetworkHeader: Codable, Hashable {
    let sourceIPs: String
    let sourceMACs: String
    let interfaces: String
    let physicalInterfaces: String
    let connectionTypes: String
    let vpnStates: String
    let proxyStates: String?
    let dnsServers: String

    init(flows: [Flow], internetChecks: [InternetCheck] = []) {
        let sources = flows.flatMap(\.attempts).map(\.source) + internetChecks.map(\.source)
        func joined(_ values: [String]) -> String {
            let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let unique = Array(Set(cleaned)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return unique.isEmpty ? "Unavailable" : unique.joined(separator: "; ")
        }
        sourceIPs = joined(sources.map(\.sourceIP))
        sourceMACs = joined(sources.map(\.sourceMAC))
        interfaces = joined(sources.map(\.interfaceName))
        physicalInterfaces = joined(sources.map(\.physicalInterfaceName))
        connectionTypes = joined(sources.map(\.connectionType))
        vpnStates = joined(sources.map { $0.vpnActive.map { $0 ? "Yes" : "No" } ?? "Unknown" })
        proxyStates = joined(sources.map { $0.proxyUsed.map { $0 ? "Yes" : "No" } ?? "Unknown" })
        dnsServers = joined(sources.flatMap(\.dnsServers))
    }
}

enum DestinationClassifier {
    static func category(for host: String) -> String {
        let value = host.lowercased()
        if value.contains("nextink") { return "Nextink" }
        if ["microsoft.com", "office.com", "office365.com", "microsoftonline.com", "live.com"].contains(where: { value == $0 || value.hasSuffix("." + $0) }) { return "Microsoft 365" }
        if ["symantec.com", "broadcom.com"].contains(where: { value == $0 || value.hasSuffix("." + $0) }) { return "Symantec" }
        return "General"
    }
}

struct ReportJSONSummary: Codable, Hashable {
    var testCount: Int
    var completed: Int
    var failed: Int
}
struct ReportJSONAttempt: Codable, Hashable {
    var number: Int
    var status: String
    var detail: String
    var milliseconds: Int?
    var testedAt: String
    var certificate: CertificateSummary?
}
struct ReportJSONTest: Codable, Hashable {
    var id: UUID
    var category: String
    var name: String
    var comment: String
    var host: String
    var port: UInt16
    var proto: String
    var payload: String
    var status: String
    var detail: String
    var milliseconds: Int?
    var testedAt: String
    var attempts: [ReportJSONAttempt]
    enum CodingKeys: String, CodingKey { case id, category, name, comment, host, port, proto = "protocol", payload, status, detail, milliseconds, testedAt, attempts }
    init(flow: Flow) {
        id = flow.id; category = flow.category; name = flow.name; comment = flow.comment; host = flow.host; port = flow.port; proto = flow.proto; payload = flow.payload
        status = flow.status; detail = flow.detail; milliseconds = flow.milliseconds; testedAt = flow.testedAt
        attempts = flow.attempts.map { ReportJSONAttempt(number: $0.number, status: $0.status, detail: $0.detail, milliseconds: $0.milliseconds, testedAt: $0.testedAt, certificate: $0.certificate) }
    }
}
struct ReportJSONDocument: Codable, Hashable {
    var schemaVersion = 1
    var importedSourceMetadata: [String: String]? = nil
    var importedFilename: String? = nil
    var reportName: String
    var createdAt: Date
    var summary: ReportJSONSummary
    var publicIP: String?
    var internetStatus: String?
    var internetChecks: [InternetCheck]
    var network: ReportNetworkHeader
    var tests: [ReportJSONTest]
}

struct ProbeResult {
    var status: String
    var detail: String
    var milliseconds: Int?
    var testedAt: String
    var source: SourceInfo
    var certificate: CertificateSummary? = nil
}
enum RetryPolicy {
    static func maximumAttempts(retriesAfterFailure: Int) -> Int { max(0, retriesAfterFailure) + 1 }
    static func shouldRetry(status: String, completedAttempts: Int, retriesAfterFailure: Int) -> Bool {
        ["Closed", "Error", "Inconclusive"].contains(status) && completedAttempts <= max(0, retriesAfterFailure)
    }
}
enum RunSafetyPolicy {
    static let largeRunWarningThreshold = 100
    static func shouldWarn(selectedFlowCount: Int) -> Bool {
        selectedFlowCount >= largeRunWarningThreshold
    }
    static func maximumPossibleAttempts(selectedFlowCount: Int, retriesAfterFailure: Int) -> Int {
        max(0, selectedFlowCount) * RetryPolicy.maximumAttempts(retriesAfterFailure: retriesAfterFailure)
    }
}
enum ScheduleUnit: String, CaseIterable, Codable {
    case minutes = "Minutes"
    case hours = "Hours"
    case days = "Days"
    var seconds: TimeInterval {
        switch self { case .minutes: 60; case .hours: 3_600; case .days: 86_400 }
    }
    static func normalizedCount(_ count: Int) -> Int { min(60, max(1, count)) }
    static func interval(count: Int, unit: ScheduleUnit) -> TimeInterval { TimeInterval(max(1, count)) * unit.seconds }
}
final class Probe {
    private let queue = DispatchQueue(label: "NetworkPortEval.probe")
    private var connection: NWConnection?
    private var finished = false
    private var completion: ((ProbeResult) -> Void)?
    private var start = Date()
    private var flow: Flow?
    private var latestPath: NWPath?
    private var httpsRequest: HTTPSRequest?
    private var proxyConfigured: Bool?
    private var proxyUsed: Bool?

    func run(_ flow: Flow, timeout: Double, completion: @escaping (ProbeResult) -> Void) {
        queue.async {
            self.completion = completion; self.start = Date(); self.flow = flow
            self.proxyConfigured = nil; self.proxyUsed = nil
            if flow.proto == "HTTPS" {
                var components = URLComponents()
                components.scheme = "https"; components.host = flow.host; components.port = Int(flow.port); components.path = "/"
                guard let url = components.url else { self.finish("Error", "Could not create HTTPS URL."); return }
                let request = HTTPSRequest(url: url, timeout: timeout, method: "HEAD")
                self.httpsRequest = request
                request.start { _, response, certificate, proxyUsed, error in
                    let valid = certificate?.trusted == true
                    let status = valid ? "Open" : "Error"
                    var detail = certificate?.detail ?? error?.localizedDescription ?? "TLS handshake failed before a certificate was supplied."
                    if let certificate {
                        detail += " Subject: \(certificate.subject). Issuer: \(certificate.issuer). Expires: \(certificate.expiresAt). SHA-256: \(certificate.sha256)."
                    }
                    if let statusCode = response?.statusCode { detail += " HTTP \(statusCode)." }
                    self.queue.async {
                        self.proxyConfigured = nil
                        self.proxyUsed = proxyUsed
                        self.finish(status, detail, measured: valid, certificate: certificate)
                    }
                }
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(flow.host), port: NWEndpoint.Port(rawValue: flow.port)!, using: flow.proto == "TCP" ? .tcp : .udp)
            self.connection = connection
            connection.stateUpdateHandler = { state in
                self.latestPath = connection.currentPath ?? self.latestPath
                switch state {
                case .ready:
                    if #available(macOS 14.0, *) {
                        connection.requestEstablishmentReport(queue: self.queue) { report in
                            self.proxyConfigured = report?.proxyConfigured
                            self.proxyUsed = report?.usedProxy
                            self.handleReady(connection, flow: flow)
                        }
                    } else {
                        self.handleReady(connection, flow: flow)
                    }
                case .failed(let error): self.fail(error)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.finish("Inconclusive", flow.proto == "UDP" ? "No UDP response: open, filtered, or probe ignored." : "Timed out: connection unconfirmed (possibly filtered or unreachable).")
            }
        }
    }
    func cancel() { queue.async { self.finish("Cancelled", "Test interrupted.") } }
    private func fail(_ error: NWError) {
        if case .posix(let code) = error, code == .ECONNREFUSED { finish("Closed", "Connection refused by destination.") }
        else { finish("Error", error.localizedDescription) }
    }
    private func finish(_ status: String, _ detail: String, measured: Bool = false, certificate: CertificateSummary? = nil) {
        guard !finished else { return }; finished = true
        let path = connection?.currentPath ?? latestPath
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        let callback = completion; completion = nil
        let host = flow?.host ?? ""
        let latency = measured ? Int(Date().timeIntervalSince(start) * 1000) : nil
        let testedAt = ISO8601DateFormatter().string(from: Date())
        let proxyConfigured = self.proxyConfigured
        let proxyUsed = self.proxyUsed
        httpsRequest?.cancel(); httpsRequest = nil
        DispatchQueue.global(qos: .utility).async {
            var source = NetworkSource.inspect(host: host, path: path)
            source.proxyConfigured = proxyConfigured
            source.proxyUsed = proxyUsed
            callback?(ProbeResult(status: status, detail: detail, milliseconds: latency, testedAt: testedAt, source: source, certificate: certificate))
        }
    }
    private func handleReady(_ connection: NWConnection, flow: Flow) {
        guard !finished else { return }
        if flow.proto == "TCP" { finish("Open", "TCP connection established.", measured: true) }
        else {
            let data = CSV.hex(flow.payload).flatMap { $0.isEmpty ? nil : $0 } ?? Data("NetworkPortEval".utf8)
            connection.send(content: data, completion: .contentProcessed { error in if let error { self.fail(error) } })
            connection.receiveMessage { data, _, _, error in
                if let error { self.fail(error) }
                else if let data { self.finish("Open", "UDP response received (\(data.count) bytes).", measured: true) }
            }
        }
    }
}

final class HTTPSRequest: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let url: URL
    private let timeout: TimeInterval
    private let method: String
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var certificate: CertificateSummary?
    private var callback: ((Data?, HTTPURLResponse?, CertificateSummary?, Bool?, Error?) -> Void)?
    private var proxyUsed: Bool?

    init(url: URL, timeout: TimeInterval, method: String) {
        self.url = url; self.timeout = timeout; self.method = method
    }
    func start(_ callback: @escaping (Data?, HTTPURLResponse?, CertificateSummary?, Bool?, Error?) -> Void) {
        self.callback = callback
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let details = self.lock.withLock { self.certificate }
            let completion = self.callback; self.callback = nil
            let proxy = self.lock.withLock { self.proxyUsed }
            completion?(data, response as? HTTPURLResponse, details, proxy, error)
            self.session?.finishTasksAndInvalidate(); self.session = nil; self.task = nil
        }
        self.task = task; task.resume()
    }
    func cancel() { task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host
        var trustError: CFError?
        let trusted = TLSCertificatePolicy.evaluate(trust, host: host, error: &trustError)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let leaf = chain.first
        let issuer = chain.count > 1 ? (SecCertificateCopySubjectSummary(chain[1]) as String? ?? "Unknown issuer") : "No issuer certificate presented"
        let hash = leaf.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)).map { String(format: "%02X", $0) }.joined() } ?? ""
        let expires = leaf.flatMap { certificateExpiry($0) }.map { ISO8601DateFormatter().string(from: $0) } ?? "Unavailable"
        let detail = trusted ? "System trust and hostname validation passed." : "Certificate validation failed: \(trustError?.localizedDescription ?? "untrusted certificate")"
        let summary = CertificateSummary(host: host, subject: leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unknown subject", issuer: issuer, sha256: hash, expiresAt: expires, trusted: trusted, detail: detail)
        lock.withLock { certificate = summary }
        if trusted { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Keep certificate and reachability results bound to the user-selected host; never follow to a second destination.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let proxy = metrics.transactionMetrics.last?.isProxyConnection
        lock.withLock { proxyUsed = proxy }
    }
    private func certificateExpiry(_ certificate: SecCertificate) -> Date? {
        if #available(macOS 15.0, *) { return SecCertificateCopyNotValidAfterDate(certificate) as Date? }
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let value = entry[kSecPropertyKeyValue] else { return nil }
        return value as? Date
    }
}

enum TLSCertificatePolicy {
    static func evaluate(_ trust: SecTrust, host: String, error: inout CFError?) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, &error)
    }
}

enum NetworkSource {
    static func isTunnelInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp"].contains(where: { name.hasPrefix($0) })
    }
    static func selectedInterfaceName(routeInterface: String, pathInterfaceNames: [String]) -> String {
        if !routeInterface.isEmpty { return routeInterface }
        return pathInterfaceNames.first(where: isTunnelInterface) ?? pathInterfaceNames.first ?? ""
    }
    static func tunnelStatus(routeInterface: String, pathInterfaceNames: [String]) -> Bool? {
        if !routeInterface.isEmpty { return isTunnelInterface(routeInterface) }
        return pathInterfaceNames.contains(where: isTunnelInterface) ? true : nil
    }
    static func macAddress(from ifconfigOutput: String) -> String? {
        guard let value = capture(#"(?m)^\s*(?:ether|lladdr)\s+([0-9a-fA-F:]+)"#, from: ifconfigOutput) else { return nil }
        return formattedMAC(value.split(separator: ":").compactMap { UInt8($0, radix: 16) })
    }
    static func formattedMAC(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), !bytes.dropFirst().allSatisfy({ $0 == 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
    static func systemMACAddress(interfaceName: String) -> String? {
        guard !interfaceName.isEmpty else { return nil }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }

        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let entry = item.pointee
            if String(cString: entry.ifa_name) == interfaceName,
               let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK) {
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                let length = Int(link.sdl_alen)
                if length == 6 {
                    let octets = UnsafeRawPointer(address).assumingMemoryBound(to: UInt8.self)
                    let start = dataOffset + Int(link.sdl_nlen)
                    let bytes = Array(UnsafeBufferPointer(start: octets.advanced(by: start), count: length))
                    if let mac = formattedMAC(bytes) { return mac }
                }
            }
            current = entry.ifa_next
        }
        return nil
    }
    static func ipv6Address(from ifconfigOutput: String) -> String? {
        let pattern = #"(?m)^\s*inet6\s+([0-9a-fA-F:]+)(?:%\S+)?\s+prefixlen"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = ifconfigOutput as NSString
        let addresses = regex.matches(in: ifconfigOutput, range: NSRange(location: 0, length: ns.length)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: ifconfigOutput) else { return nil }
            let value = String(ifconfigOutput[range])
            var address = in6_addr()
            return value != "::" && value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 ? value.lowercased() : nil
        }
        return addresses.first(where: { !$0.hasPrefix("fe80:") }) ?? addresses.first
    }
    static func sourceAddress(from endpointHost: NWEndpoint.Host) -> String? {
        let value: String
        switch endpointHost {
        case .ipv4(let address): value = String(describing: address)
        case .ipv6(let address): value = String(describing: address)
        case .name: return nil
        @unknown default: return nil
        }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return value }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return value.lowercased() }
        return nil
    }
    static func sourceAddress(from path: NWPath?) -> String? {
        guard let endpoint = path?.localEndpoint, case let .hostPort(host, _) = endpoint else { return nil }
        return sourceAddress(from: host)
    }
    static func inspect(host: String, path: NWPath?) -> SourceInfo {
        var info = SourceInfo()
        let routeOutput = run("/sbin/route", ["-n", "get", host])
        let routedInterface = routeOutput.flatMap { capture(#"(?m)^\s*interface:\s*(\S+)"#, from: $0) } ?? ""
        let interfaces = path?.availableInterfaces ?? []
        let pathTunnel = interfaces.first(where: { isTunnelInterface($0.name) })?.name ?? ""
        // availableInterfaces is a preference list, not proof of the interface carrying this connection.
        // Use the destination-specific route when available; only report a tunnel if the path exposes one.
        info.interfaceName = selectedInterfaceName(routeInterface: routedInterface, pathInterfaceNames: pathTunnel.isEmpty ? [] : [pathTunnel])
        let interfaceDetails = info.interfaceName.isEmpty ? nil : run("/sbin/ifconfig", [info.interfaceName])
        info.sourceIP = sourceAddress(from: path) ?? interfaceDetails.flatMap { capture(#"(?m)^\s*inet\s+([0-9.]+)"#, from: $0) } ?? interfaceDetails.flatMap(ipv6Address(from:)) ?? ""
        let interface = path?.availableInterfaces.first(where: { $0.name == info.interfaceName })
        let physical = interfaces.first(where: { $0.type == .wifi || $0.type == .wiredEthernet })
        if let physical { info.physicalInterfaceName = physical.name }
        info.vpnActive = tunnelStatus(routeInterface: routedInterface, pathInterfaceNames: !pathTunnel.isEmpty ? [pathTunnel] : [])
        let usesTunnelRoute = info.vpnActive == true
        if usesTunnelRoute {
            info.vpnActive = true
            let underlying = physical?.type == .wifi ? "Wi-Fi" : physical?.type == .wiredEthernet ? "Ethernet" : "unknown connection"
            info.connectionType = "VPN tunnel over \(underlying)"
        } else if let interface, interface.type == .wifi || interface.type == .wiredEthernet {
            if info.vpnActive == nil, !routedInterface.isEmpty { info.vpnActive = false }
            info.connectionType = interface.type == .wifi ? "Wi-Fi" : "Ethernet"
            info.physicalInterfaceName = interface.name
            info.sourceMAC = systemMACAddress(interfaceName: info.interfaceName) ?? interfaceDetails.flatMap(macAddress(from:)) ?? ""
        } else if let interface {
            if info.vpnActive == nil, !routedInterface.isEmpty { info.vpnActive = false }
            switch interface.type {
            case .wifi: info.connectionType = "Wi-Fi"
            case .wiredEthernet: info.connectionType = "Ethernet"
            case .cellular: info.connectionType = "Cellular"
            case .loopback: info.connectionType = "Loopback"
            case .other: info.connectionType = "Other"
            @unknown default: info.connectionType = "Other"
            }
        } else if !info.interfaceName.isEmpty {
            info.connectionType = hardwarePortName(device: info.interfaceName) ?? (info.interfaceName.hasPrefix("en") ? "Ethernet or Wi-Fi" : "Other")
            if info.vpnActive == nil, !routedInterface.isEmpty { info.vpnActive = false }
            if !usesTunnelRoute { info.sourceMAC = systemMACAddress(interfaceName: info.interfaceName) ?? interfaceDetails.flatMap(macAddress(from:)) ?? "" }
        } else if path?.usesInterfaceType(.wifi) == true {
            info.connectionType = "Wi-Fi"
        } else if path?.usesInterfaceType(.wiredEthernet) == true {
            info.connectionType = "Ethernet"
        }
        info.dnsServers = configuredDNSServers()
        return info
    }
    static func configuredDNSServers() -> [String] {
        guard let output = run("/usr/sbin/scutil", ["--dns"]) else { return [] }
        let pattern = #"(?m)^\s*nameserver\[\d+\]\s*:\s*(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = output as NSString
        return Array(Set(regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).compactMap { Range($0.range(at: 1), in: output).map { String(output[$0]) } })).sorted()
    }
    private static func hardwarePortName(device: String) -> String? {
        guard let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        for block in output.components(separatedBy: "\n\n") where block.contains("Device: \(device)") {
            return capture(#"(?m)^Hardware Port:\s*(.+)$"#, from: block)
        }
        return nil
    }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        let outputRead = DispatchSemaphore(value: 0)
        let outputLock = NSLock()
        var outputData = Data()
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                outputLock.withLock { outputData = data }
                outputRead.signal()
            }
            guard terminated.wait(timeout: .now() + max(0.1, timeout)) == .success else {
                process.terminate()
                if terminated.wait(timeout: .now() + 0.25) != .success {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 0.5)
                }
                return nil
            }
            process.waitUntilExit()
            guard outputRead.wait(timeout: .now() + 0.5) == .success else { return nil }
            guard process.terminationStatus == 0 else { return nil }
            return outputLock.withLock { String(data: outputData, encoding: .utf8) }
        }
        catch { return nil }
    }
    private static func capture(_ pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

struct InternetDiagnostics {
    var publicIP: String?
    var status: String
    var checks: [InternetCheck]
    static func run() async -> InternetDiagnostics {
        async let publicIPResult = lookupPublicIP()
        async let checks = [check("Google", "https://www.google.com/generate_204", expected: 204), check("Apple", "https://www.apple.com/library/test/success.html", expected: 200)]
        let ipResult = await publicIPResult
        let outcomes = await checks
        let working = outcomes.filter { $0.result == "Reachable" }.count
        let hasUnexpected = outcomes.contains { $0.result.hasPrefix("Unexpected response") }
        let state = working == 2 ? "Internet available" : working == 1 ? "Internet available (one check failed)" : hasUnexpected ? "Unexpected web response (possible captive portal or proxy)" : "No external web response (offline or filtered)"
        var allChecks = outcomes
        allChecks.append(ipResult.check)
        return InternetDiagnostics(publicIP: ipResult.ip, status: state, checks: allChecks)
    }
    private struct Response {
        var data: Data?
        var http: HTTPURLResponse?
        var certificate: CertificateSummary?
        var error: String?
    }
    private static func fetch(_ url: URL, method: String, timeout: TimeInterval) async -> Response {
        await withCheckedContinuation { continuation in
            let request = HTTPSRequest(url: url, timeout: timeout, method: method)
            request.start { data, response, certificate, _, error in
                continuation.resume(returning: Response(data: data, http: response, certificate: certificate, error: error?.localizedDescription))
            }
        }
    }
    private static func lookupPublicIP() async -> (ip: String?, check: InternetCheck) {
        let url = URL(string: "https://api.ipify.org")!
        let response = await fetch(url, method: "GET", timeout: 4)
        let ip = response.data.flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let valid = ip.map(isIPAddress) ?? false
        let source = NetworkSource.inspect(host: url.host ?? "api.ipify.org", path: nil)
        let certificateValid = response.certificate?.trusted == true
        let reachable = response.http?.statusCode == 200 && valid && certificateValid
        let result = reachable ? "Reachable" : response.certificate?.trusted == false ? "Certificate validation failed" : response.http == nil ? "No response" : "Unexpected response"
        let detail = response.error ?? (reachable ? "Returned the public egress IP." : "Expected a trusted HTTPS certificate and a plain-text IP address.")
        let check = InternetCheck(service: "api.ipify.org", result: result, httpStatus: response.http?.statusCode, detail: detail, source: source, certificate: response.certificate)
        return (reachable ? ip : nil, check)
    }
    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
    private static func check(_ name: String, _ address: String, expected: Int) async -> InternetCheck {
        let url = URL(string: address)!
        let response = await fetch(url, method: "GET", timeout: 5)
        let body = response.data ?? Data()
        let bodyText = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payloadMatches = name == "Google" ? body.isEmpty : bodyText.localizedCaseInsensitiveContains("success")
        let certificateValid = response.certificate?.trusted == true
        let reachable = response.http?.statusCode == expected && payloadMatches && certificateValid
        let result = reachable ? "Reachable" : response.certificate?.trusted == false ? "Certificate validation failed" : response.http == nil ? "No response" : "Unexpected response (possible captive portal or proxy)"
        let detail = response.error ?? (name == "Google" ? "Expected HTTP 204 with an empty body and a valid host certificate." : "Expected HTTP 200 with a Success response and a valid host certificate.")
        return InternetCheck(service: name, result: result, httpStatus: response.http?.statusCode, detail: detail, source: NetworkSource.inspect(host: url.host ?? name, path: nil), certificate: response.certificate)
    }
}
