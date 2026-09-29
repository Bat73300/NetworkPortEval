import AppKit
import CoreText

enum PDFReport {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 42
    private static let ink = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.27, alpha: 1)
    private static let muted = NSColor(calibratedRed: 0.39, green: 0.45, blue: 0.55, alpha: 1)
    private static let blue = NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.96, alpha: 1)
    private static let paleBlue = NSColor(calibratedRed: 0.92, green: 0.96, blue: 1, alpha: 1)
    private static let paleGray = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    private static let green = NSColor(calibratedRed: 0.10, green: 0.59, blue: 0.35, alpha: 1)
    private static let red = NSColor(calibratedRed: 0.78, green: 0.22, blue: 0.24, alpha: 1)
    private static let orange = NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.10, alpha: 1)
    private static let contentBottom: CGFloat = 790

    static func write(_ report: SavedReport, to url: URL, locale: Locale = .current, translate: (String) -> String) throws {
        var mediaBox = page
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CSV.error("Could not create PDF.")
        }
        let writer = Writer(context: context)
        let network = ReportNetworkHeader(flows: report.flows, internetChecks: report.internetChecks ?? [])
        let total = report.flows.count
        let open = report.flows.filter { $0.status == "Open" }.count
        let failed = report.flows.filter { ["Closed", "Error"].contains($0.status) }.count
        let inconclusive = report.flows.filter { $0.status == "Inconclusive" }.count
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        writer.beginPage(section: translate("Network report"))
        writer.brandMark(x: margin, top: 36)
        writer.text("NetworkPortEval", x: margin + 42, top: 35, width: 300, size: 20, weight: .bold, color: ink)
        writer.text(translate("Network evaluation utility for Mac devices"), x: margin + 42, top: 61, width: 360, size: 9, color: muted)
        writer.text("BC performances", x: page.width - margin - 140, top: 42, width: 140, size: 9, weight: .semibold, color: blue, alignment: .right)
        writer.rule(y: 88)

        writer.text(translate("Network report"), x: margin, top: 108, width: 475, size: 24, weight: .bold, color: ink)
        writer.text(report.name, x: margin, top: 141, width: 475, size: 12, weight: .semibold, color: blue)
        writer.text("\(translate("Date:")) \(dateFormatter.string(from: report.createdAt))", x: margin, top: 161, width: 475, size: 9, color: muted)
        writer.text(translate("A clear view of your Mac’s network connectivity."), x: margin, top: 186, width: 475, size: 10, weight: .medium, color: muted)

        let cardTop: CGFloat = 218
        let gap: CGFloat = 10
        let cardWidth = (page.width - margin * 2 - gap * 3) / 4
        let metrics: [(String, Int, NSColor)] = [
            (translate("Tests:"), total, blue),
            (translate("Open"), open, green),
            (translate("Failed"), failed, red),
            (translate("Inconclusive"), inconclusive, orange)
        ]
        for (index, metric) in metrics.enumerated() {
            writer.metricCard(title: metric.0, value: metric.1, x: margin + CGFloat(index) * (cardWidth + gap), top: cardTop, width: cardWidth, tint: metric.2)
        }

        var cursor: CGFloat = cardTop + 84
        cursor = writer.section(translate("Report information"), at: cursor)
        let contextLines = [
            "\(translate("Internet status:")) \(report.internetStatus.map(translate) ?? translate("Not checked"))",
            "\(translate("Public IP (api.ipify.org):")) \(report.publicIP ?? translate(report.internetStatus == nil ? "Not checked" : "Unavailable"))",
            "\(translate("Source IP / MAC:")) \(network.sourceIPs.components(separatedBy: "; ").map(translate).joined(separator: "; ")) / \(network.sourceMACs.components(separatedBy: "; ").map(translate).joined(separator: "; "))",
            "\(translate("Interface / connection:")) \(network.interfaces.components(separatedBy: "; ").map(translate).joined(separator: "; ")) [\(network.physicalInterfaces.components(separatedBy: "; ").map(translate).joined(separator: "; "))] · \(network.connectionTypes.components(separatedBy: "; ").map(translate).joined(separator: "; "))",
            "\(translate("VPN active:")) \(network.vpnStates.components(separatedBy: "; ").map(translate).joined(separator: "; "))",
            "\(translate("System proxy used:")) \(network.proxyStates.map { $0.components(separatedBy: "; ").map(translate).joined(separator: "; ") } ?? translate("Proxy use unknown"))",
            "\(translate("Configured DNS servers:")) \(network.dnsServers.components(separatedBy: "; ").map(translate).joined(separator: "; "))"
        ]
        if let origin = report.imported {
            cursor = writer.bodyCard(translate("Imported") + " · " + origin.filename + " · " + (origin.computer ?? "") + "\n" + translate("Imported results; no tests were run on this Mac."), at: cursor)
            let keys = ["Source IP address(es)", "Local MAC address(es)", "Route interface(s)", "Physical interface(s)", "Connection type(s)", "VPN active", "System proxy used", "Configured DNS server(s)"]
            let importedContext = Array(contextLines.prefix(2)) + keys.compactMap { key in origin.metadata[key].map { translate(key) + ": " + translate($0) } }
            cursor = writer.infoCard(importedContext, at: cursor)
        } else { cursor = writer.infoCard(contextLines, at: cursor) }
        cursor = writer.bodyCard(translate("Hostnames use the macOS system DNS resolver. Configured servers are listed, but macOS does not report which one answered a lookup. You cannot choose a DNS server in NetworkPortEval."), at: cursor)

        if let checks = report.internetChecks, !checks.isEmpty {
            cursor = writer.section(translate("Internet checks"), at: cursor + 10)
            let checkText = checks.map { check in
                let certificate = check.certificate.map {
                    "TLS \($0.trusted ? translate("Valid") : translate("Invalid")) · \($0.host) ·  \(translate("subject")) \($0.subject) ·  \(translate("issuer")) \($0.issuer) ·  \(translate("expires")) \($0.expiresAt) · SHA-256 \($0.sha256)"
                } ?? ""
                return ["\(check.service): \(translate(check.result))\(check.httpStatus.map { " · HTTP \($0)" } ?? "")", translate(check.detail), certificate].filter { !$0.isEmpty }.joined(separator: " — ")
            }.joined(separator: "\n")
            cursor = writer.bodyCard(checkText, at: cursor)
        }

        let preparedRows = report.flows.map { flow -> (Flow, ProbeAttempt, String, CGFloat) in
            let attempts = flow.attempts.isEmpty
                ? [ProbeAttempt(number: 0, status: flow.status, detail: flow.detail, milliseconds: flow.milliseconds, testedAt: flow.testedAt)]
                : flow.attempts
            let latest = attempts.last!
            let detailParts = attempts.map { attempt -> String in
                let prefix = attempt.number == 0 ? translate(attempt.status) : "#\(attempt.number) · \(translate(attempt.status))"
                let latency = attempt.milliseconds.map { " · \($0) ms" } ?? ""
                let certificate = attempt.certificate.map {
                    "TLS \($0.trusted ? translate("Valid") : translate("Invalid")) · \($0.host) ·  \(translate("subject")) \($0.subject) ·  \(translate("issuer")) \($0.issuer) ·  \(translate("expires")) \($0.expiresAt) · SHA-256 \($0.sha256)"
                } ?? ""
                return [prefix + latency, translate(attempt.detail), certificate].filter { !$0.isEmpty }.joined(separator: " — ")
            }
            let details = detailParts.joined(separator: "\n")
            let rowHeight = writer.flowRowHeight(flow: flow, detail: details)
            return (flow, latest, details, rowHeight)
        }
        // Keep the heading and column labels with the first result.
        if cursor + 10 + 22 + 28 + (preparedRows.first?.3 ?? 36) > contentBottom {
            writer.endPage()
            writer.beginPage(section: translate("Test results"))
            cursor = 94
        }
        cursor = writer.section(translate("Test results"), at: cursor + 10)
        writer.tableHeader(at: cursor, translate: translate)
        cursor += 28
        if report.flows.isEmpty {
            writer.text(translate("No test flows were included in this report."), x: margin, top: cursor + 12, width: page.width - margin * 2, size: 9, color: muted)
            cursor += 36
        }
        for (flow, latest, details, rowHeight) in preparedRows {
            if cursor + rowHeight > contentBottom {
                writer.endPage()
                writer.beginPage(section: translate("Test results"))
                cursor = writer.section(translate("Test results — continued"), at: 104)
                writer.tableHeader(at: cursor, translate: translate)
                cursor += 28
            }
            writer.flowRow(flow: flow, status: translate(latest.status), latency: latest.milliseconds, details: details, at: cursor, height: rowHeight)
            cursor += rowHeight
        }

        cursor += 12
        if cursor + 112 > contentBottom {
            writer.endPage()
            writer.beginPage(section: translate("About NetworkPortEval"))
            cursor = 105
        }
        writer.promoCard(at: cursor, privacyWarning: translate("The report may include hostnames, tested services, public and local IP addresses, MAC addresses, DNS and VPN details. Redact anything sensitive before sending."), encryptionNotice: translate("Saved reports are stored locally and are not encrypted by the app."), translate: translate)
        writer.endPage()
        writer.finish()
    }

    private enum Weight { case regular, medium, semibold, bold }
    private enum Alignment { case left, right }

    private final class Writer {
        private let context: CGContext
        private var pageNumber = 0
        private var isPageOpen = false

        init(context: CGContext) { self.context = context }

        func beginPage(section: String) {
            if isPageOpen { endPage() }
            pageNumber += 1
            context.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
            isPageOpen = true
            context.setFillColor(NSColor.white.cgColor)
            context.fill(page)
            if pageNumber > 1 {
                brandMark(x: margin, top: 28, size: 22)
                text("NetworkPortEval", x: margin + 31, top: 30, width: 210, size: 10, weight: .bold, color: ink)
                text(section, x: page.width - margin - 245, top: 31, width: 245, size: 8, color: muted, alignment: .right)
                rule(y: 64)
            }
            roundedRect(CGRect(x: margin, y: 18, width: page.width - margin * 2, height: 1), color: paleGray, radius: 0)
            text("NetworkPortEval  ·  BC performances  ·  bcperf@gmail.com", x: margin, top: 808, width: 410, size: 7, color: muted)
            text("\(pageNumber)", x: page.width - margin - 28, top: 807, width: 28, size: 8, weight: .semibold, color: blue, alignment: .right)
        }

        func endPage() {
            guard isPageOpen else { return }
            context.endPDFPage()
            isPageOpen = false
        }

        func finish() { context.closePDF() }

        @discardableResult
        func text(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat, weight: Weight = .regular, color: NSColor, alignment: Alignment = .left) -> CGFloat {
            let fontName: String
            switch weight {
            case .regular: fontName = ".AppleSystemUIFont"
            case .medium: fontName = ".AppleSystemUIFontMedium"
            case .semibold: fontName = ".AppleSystemUIFontSemibold"
            case .bold: fontName = ".AppleSystemUIFontBold"
            }
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment == .left ? .left : .right
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: value, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            var fitRange = CFRange()
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: attributed.length), nil, CGSize(width: width, height: 2_000), &fitRange)
            let height = max(size * 1.25, ceil(suggested.height) + 1)
            let rect = CGRect(x: x, y: page.height - top - height, width: width, height: height)
            let path = CGPath(rect: rect, transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil), context)
            return height
        }

        func rule(y: CGFloat) {
            context.setStrokeColor(paleGray.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: margin, y: page.height - y))
            context.addLine(to: CGPoint(x: page.width - margin, y: page.height - y))
            context.strokePath()
        }

        func roundedRect(_ rect: CGRect, color: NSColor, radius: CGFloat) {
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        func brandMark(x: CGFloat, top: CGFloat, size: CGFloat = 32) {
            let rect = CGRect(x: x, y: page.height - top - size, width: size, height: size)
            context.setStrokeColor(blue.cgColor)
            context.setLineWidth(1.7)
            context.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
            context.strokeEllipse(in: CGRect(x: rect.minX + size * 0.29, y: rect.minY + 2, width: size * 0.42, height: size - 4))
            context.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            context.move(to: CGPoint(x: rect.minX + 5, y: rect.minY + size * 0.31))
            context.addCurve(to: CGPoint(x: rect.maxX - 5, y: rect.minY + size * 0.31), control1: CGPoint(x: rect.minX + size * 0.34, y: rect.minY + size * 0.23), control2: CGPoint(x: rect.maxX - size * 0.34, y: rect.minY + size * 0.23))
            context.move(to: CGPoint(x: rect.minX + 5, y: rect.minY + size * 0.69))
            context.addCurve(to: CGPoint(x: rect.maxX - 5, y: rect.minY + size * 0.69), control1: CGPoint(x: rect.minX + size * 0.34, y: rect.minY + size * 0.77), control2: CGPoint(x: rect.maxX - size * 0.34, y: rect.minY + size * 0.77))
            context.strokePath()
        }

        func metricCard(title: String, value: Int, x: CGFloat, top: CGFloat, width: CGFloat, tint: NSColor) {
            let rect = CGRect(x: x, y: page.height - top - 66, width: width, height: 66)
            roundedRect(rect, color: paleGray, radius: 10)
            context.setFillColor(tint.cgColor)
            context.fill(CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
            text(title, x: x + 12, top: top + 10, width: width - 22, size: 8, weight: .semibold, color: tint)
            text(String(value), x: x + 12, top: top + 27, width: width - 22, size: 21, weight: .bold, color: ink)
        }

        func section(_ title: String, at top: CGFloat) -> CGFloat {
            text(title.uppercased(), x: margin, top: top, width: page.width - margin * 2, size: 8, weight: .bold, color: blue)
            let lineY = page.height - top - 14
            context.setStrokeColor(paleGray.cgColor); context.setLineWidth(1)
            context.move(to: CGPoint(x: margin, y: lineY)); context.addLine(to: CGPoint(x: page.width - margin, y: lineY)); context.strokePath()
            return top + 22
        }

        func infoCard(_ lines: [String], at top: CGFloat) -> CGFloat {
            let height = CGFloat(lines.count) * 15 + 18
            let rect = CGRect(x: margin, y: page.height - top - height, width: page.width - margin * 2, height: height)
            roundedRect(rect, color: paleBlue, radius: 9)
            for (index, line) in lines.enumerated() {
                text(line, x: margin + 13, top: top + 9 + CGFloat(index) * 15, width: page.width - margin * 2 - 26, size: 8, color: ink)
            }
            return top + height + 7
        }

        func bodyCard(_ value: String, at top: CGFloat) -> CGFloat {
            let height = max(43, textHeight(value, width: page.width - margin * 2 - 26, size: 8) + 20)
            let rect = CGRect(x: margin, y: page.height - top - height, width: page.width - margin * 2, height: height)
            roundedRect(rect, color: paleGray, radius: 8)
            _ = text(value, x: margin + 13, top: top + 10, width: page.width - margin * 2 - 26, size: 8, color: ink)
            return top + height + 7
        }

        func tableHeader(at top: CGFloat, translate: (String) -> String) {
            let rect = CGRect(x: margin, y: page.height - top - 23, width: page.width - margin * 2, height: 23)
            roundedRect(rect, color: paleGray, radius: 5)
            text(translate("Name"), x: margin + 10, top: top + 7, width: 248, size: 7, weight: .bold, color: muted)
            text("\(translate("Host")) / \(translate("Protocol"))", x: margin + 264, top: top + 7, width: 74, size: 7, weight: .bold, color: muted)
            text(translate("Status"), x: margin + 345, top: top + 7, width: 150, size: 7, weight: .bold, color: muted)
        }

        func flowRowHeight(flow: Flow, detail: String) -> CGFloat {
            let leftText = [flow.name, flow.category, flow.comment].filter { !$0.isEmpty }.joined(separator: " · ")
            let headingHeight = max(textHeight(leftText, width: 245, size: 8, weight: .semibold),
                                    textHeight("\(flow.host):\(flow.port)", width: 74, size: 8, weight: .medium) + 4 + textHeight(flow.proto, width: 74, size: 7, weight: .semibold), 22)
            return max(58, 8 + headingHeight + 8 + textHeight(detail, width: page.width - margin * 2 - 20, size: 7) + 10)
        }

        func flowRow(flow: Flow, status: String, latency: Int?, details: String, at top: CGFloat, height: CGFloat) {
            let rect = CGRect(x: margin, y: page.height - top - height, width: page.width - margin * 2, height: height)
            roundedRect(rect, color: pageNumber % 2 == 0 ? paleGray : NSColor.white, radius: 4)
            let left = [flow.name, flow.category, flow.comment].filter { !$0.isEmpty }.joined(separator: " · ")
            let leftHeight = text(left, x: margin + 10, top: top + 8, width: 245, size: 8, weight: .semibold, color: ink)
            let hostHeight = text("\(flow.host):\(flow.port)", x: margin + 264, top: top + 8, width: 74, size: 8, weight: .medium, color: ink)
            let protocolHeight = text(flow.proto, x: margin + 264, top: top + 8 + hostHeight + 4, width: 74, size: 7, weight: .semibold, color: blue)
            let resultColor: NSColor = flow.status == "Open" ? green : (flow.status == "Inconclusive" ? orange : (["Error", "Closed"].contains(flow.status) ? red : ink))
            _ = text("\(status)\(latency.map { " · \($0) ms" } ?? "")", x: margin + 345, top: top + 8, width: 150, size: 8, weight: .bold, color: resultColor)
            if !details.isEmpty { _ = text(details, x: margin + 10, top: top + 8 + max(leftHeight, hostHeight + 4 + protocolHeight, 22) + 8, width: page.width - margin * 2 - 20, size: 7, color: muted) }
            context.setStrokeColor(paleGray.cgColor); context.setLineWidth(0.6)
            context.move(to: CGPoint(x: margin, y: rect.minY)); context.addLine(to: CGPoint(x: page.width - margin, y: rect.minY)); context.strokePath()
        }

        func promoCard(at top: CGFloat, privacyWarning: String, encryptionNotice: String, translate: (String) -> String) {
            let rect = CGRect(x: margin, y: page.height - top - 104, width: page.width - margin * 2, height: 104)
            roundedRect(rect, color: paleBlue, radius: 10)
            text(translate("Created with NetworkPortEval"), x: margin + 14, top: top + 10, width: 290, size: 10, weight: .bold, color: ink)
            text(translate("Network connectivity insights for Mac."), x: margin + 14, top: top + 27, width: 300, size: 8, color: muted)
            text(privacyWarning, x: margin + 14, top: top + 44, width: page.width - margin * 2 - 28, size: 7, color: muted)
            text(encryptionNotice, x: margin + 14, top: top + 79, width: page.width - margin * 2 - 28, size: 7, weight: .semibold, color: muted)
            text("BC performances  ·  bcperf@gmail.com", x: margin + 285, top: top + 19, width: 200, size: 8, weight: .semibold, color: blue, alignment: .right)
        }

        private func textHeight(_ value: String, width: CGFloat, size: CGFloat, weight: Weight = .regular) -> CGFloat {
            guard !value.isEmpty else { return size * 1.25 }
            let fontName: String
            switch weight {
            case .regular: fontName = ".AppleSystemUIFont"
            case .medium: fontName = ".AppleSystemUIFontMedium"
            case .semibold: fontName = ".AppleSystemUIFontSemibold"
            case .bold: fontName = ".AppleSystemUIFontBold"
            }
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: attributed.length), nil, CGSize(width: width, height: 2_000), nil)
            return ceil(measured.height) + 1
        }
    }
}
