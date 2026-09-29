import Foundation
import CryptoKit

struct ImportedReportOrigin: Codable {
    var importedAt: Date
    var filename: String
    var computer: String?
    var fingerprint: String
    var originalID: UUID?
    // Preserve aggregate source context without attributing it to individual attempts.
    var metadata: [String: String]
}

enum ReportCSVImport {
    static func parse(_ data: Data, filename: String, computer: String? = nil) throws -> SavedReport {
        guard data.count <= 5_000_000 else { throw CSV.error("Maximum: 5 MB per CSV.") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw CSV.error("Save the CSV using UTF-8 encoding.")
        }
        let rows = try CSV.records(text)
        guard let table = rows.firstIndex(where: { $0.contains("host") && $0.contains("status") && $0.contains("attempt") }) else {
            throw CSV.error("Select a NetworkPortEval report CSV, not a flow template.")
        }
        var metadata: [String: String] = [:]
        let metadataKeys = ["Report", "Report name", "Created at", "Public IP", "Internet status", "Internet checks", "Source IP address(es)", "Local MAC address(es)", "Route interface(s)", "Physical interface(s)", "Connection type(s)", "VPN active", "System proxy used", "Configured DNS server(s)", "Report ID", "Format version"]
        for row in rows.prefix(table) where row.count == 2 {
            let key = metadataKeys.first { key in key == row[0] || Language.allCases.contains { $0.text(key) == row[0] } } ?? row[0]
            guard metadata[key] == nil else { throw CSV.error("Duplicate report metadata.") }
            metadata[key] = row[1]
        }
        guard metadata["Report"] == "NetworkPortEval", let name = metadata["Report name"], !name.isEmpty,
              let stamp = metadata["Created at"], let date = ISO8601DateFormatter().date(from: stamp) else {
            throw CSV.error("Missing or invalid report name/date.")
        }
        guard metadata["Format version"] == nil || metadata["Format version"] == "1" else { throw CSV.error("Unsupported report CSV version.") }
        let originalID = metadata["Report ID"].flatMap(UUID.init(uuidString:))
        if metadata["Report ID"] != nil && originalID == nil { throw CSV.error("Invalid report identifier.") }
        let headers = rows[table]
        guard Set(headers).count == headers.count,
              ["category", "name", "comment", "host", "port", "protocol", "payload_hex", "status", "detail", "latency_ms", "tested_at", "attempt"].allSatisfy(headers.contains) else { throw CSV.error("Invalid report columns.") }
        let body = Array(rows.dropFirst(table + 1))
        guard !body.isEmpty, body.count <= 10000 else { throw CSV.error("Expected 1 to 10,000 report rows.") }
        var flows: [Flow] = []
        var indexes: [[String]: Int] = [:]
        for (offset, row) in body.enumerated() {
            guard row.count == headers.count else { throw CSV.error("Invalid report row \(table + offset + 2).") }
            func value(_ key: String) -> String { headers.firstIndex(of: key).map { row[$0] } ?? "" }
            guard let port = UInt16(value("port")), port > 0,
                  let number = Int(value("attempt")), number > 0 else { throw CSV.error("Invalid port or attempt number.") }
            let status = ["Open", "Closed", "Error", "Inconclusive", "Cancelled"].first { key in
                key == value("status") || Language.allCases.contains { $0.text(key) == value("status") }
            }
            guard let status else { throw CSV.error("Unknown report status.") }
            let latency = Int(value("latency_ms"))
            guard value("latency_ms").isEmpty || (latency != nil && latency! >= 0),
                  ISO8601DateFormatter().date(from: value("tested_at")) != nil else { throw CSV.error("Invalid test date or latency.") }
            var flow = try FlowInputValidator.normalize(Flow(name: value("name"), host: value("host"), port: port, proto: value("protocol"), payload: value("payload_hex"), category: value("category"), comment: value("comment")))
            flow.selected = false
            let key = [flow.category, flow.name, flow.comment, flow.host, String(port), flow.proto, flow.payload]
            var attempt = ProbeAttempt(number: number, status: status, detail: value("detail"), milliseconds: latency, testedAt: value("tested_at"))
            if !value("tls_host").isEmpty {
                let trusted = ["Yes", "No"].first { key in key == value("tls_trusted") || Language.allCases.contains { $0.text(key) == value("tls_trusted") } }
                guard let trusted else { throw CSV.error("Invalid TLS trust value.") }
                attempt.certificate = CertificateSummary(host: value("tls_host"), subject: value("tls_subject"), issuer: value("tls_issuer"), sha256: value("tls_sha256"), expiresAt: value("tls_expires_at"), trusted: trusted == "Yes", detail: "")
            }
            let index = indexes[key] ?? flows.count
            if index == flows.count { indexes[key] = index; flows.append(flow) }
            guard !flows[index].attempts.contains(where: { $0.number == number }) else { throw CSV.error("Duplicate attempt in report.") }
            flows[index].attempts.append(attempt)
        }
        for i in flows.indices {
            flows[i].attempts.sort { $0.number < $1.number }
            let last = flows[i].attempts.last!
            flows[i].status = last.status; flows[i].detail = last.detail
            flows[i].milliseconds = last.milliseconds; flows[i].testedAt = last.testedAt
        }
        let canonical = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let origin = ImportedReportOrigin(importedAt: Date(), filename: filename, computer: computer?.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: fingerprint, originalID: originalID, metadata: metadata)
        return SavedReport(id: UUID(), name: name, createdAt: date, flows: flows, imported: origin, publicIP: metadata["Public IP"], internetStatus: metadata["Internet status"])
    }
    static func isDuplicate(_ incoming: SavedReport, in reports: [SavedReport]) -> Bool {
        guard let origin = incoming.imported else { return false }
        return reports.contains { report in
            if let id = origin.originalID, id == report.id || id == report.imported?.originalID { return true }
            return report.imported?.fingerprint == origin.fingerprint
        }
    }
}
