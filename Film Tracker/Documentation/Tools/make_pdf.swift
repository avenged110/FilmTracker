// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Renders a guide's HTML to a paginated US Letter PDF with WebKit, then stamps a footer and
// page number on every page after the cover. The PDF's title comes from the page's <title>,
// its subject from <meta name="description">, and the footer text from <meta name="footer">.
//
//   swift make_pdf.swift Sources/SearchGuide.html "Film Tracker Search Guide.pdf"
// Normally run through Documentation/Tools/build.sh.

import AppKit
import WebKit
import PDFKit

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: make_pdf <html> <pdf>\n".utf8)); exit(2) }
let htmlURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let rawURL = outURL.deletingLastPathComponent().appendingPathComponent(".raw-\(UUID().uuidString).pdf")

/// The `content` of the page's `<meta name="…">` tag, or nil when it has none.
func metaContent(_ name: String, in html: String) -> String? {
    let pattern = #"<meta\s+name="\#(name)"\s+content="([^"]*)""#
    guard let match = html.range(of: pattern, options: .regularExpression) else { return nil }
    let tag = String(html[match])
    guard let open = tag.range(of: "content=\"") else { return nil }
    return String(tag[open.upperBound...].dropLast())
}

let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
let documentTitle: String = {
    guard let open = html.range(of: "<title>"),
          let close = html.range(of: "</title>", range: open.upperBound..<html.endIndex) else {
        return htmlURL.deletingPathExtension().lastPathComponent
    }
    return String(html[open.upperBound..<close.lowerBound])
}()
let documentSubject = metaContent("description", in: html) ?? ""
let footerText = metaContent("footer", in: html) ?? documentTitle

let pageSize = NSSize(width: 612, height: 792)
let margin: CGFloat = 54        // 0.75 in

final class Loader: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error)\n".utf8)); exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let contentWidth = pageSize.width - 2 * margin
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pageSize.height))
let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView

final class Finisher: NSObject {
    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard success else { FileHandle.standardError.write(Data("print failed\n".utf8)); exit(1) }
        stamp()
        exit(0)
    }
}
let finisher = Finisher()

let loader = Loader {
    // Give layout and web fonts a moment to settle before printing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = margin
        info.bottomMargin = margin + 6
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = rawURL

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: contentWidth, height: pageSize.height)
        op.runModal(for: window, delegate: finisher, didRun: #selector(Finisher.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
}
webView.navigationDelegate = loader
webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

func stamp() {
    guard let source = CGPDFDocument(rawURL as CFURL), source.numberOfPages > 0 else {
        FileHandle.standardError.write(Data("no PDF produced\n".utf8)); exit(1)
    }
    var box = CGRect(origin: .zero, size: pageSize)
    guard let ctx = CGContext(outURL as CFURL, mediaBox: &box, [
        kCGPDFContextTitle as String: documentTitle,
        kCGPDFContextAuthor as String: "avenged110",
        kCGPDFContextSubject as String: documentSubject,
    ] as CFDictionary) else { exit(1) }

    let total = source.numberOfPages
    let font = NSFont.systemFont(ofSize: 8.5)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.52, alpha: 1)]
    for number in 1...total {
        guard let page = source.page(at: number) else { continue }
        ctx.beginPDFPage(nil)
        // Fit whatever size WebKit produced onto the letter page without distortion.
        let pageBox = page.getBoxRect(.mediaBox)
        let scale = min(pageSize.width / pageBox.width, pageSize.height / pageBox.height)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        if number > 1 {
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            let left = NSAttributedString(string: footerText, attributes: attrs)
            let right = NSAttributedString(string: "\(number - 1)", attributes: attrs)
            left.draw(at: NSPoint(x: margin, y: 30))
            right.draw(at: NSPoint(x: pageSize.width - margin - right.size().width, y: 30))
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: margin, y: 45)); rule.line(to: NSPoint(x: pageSize.width - margin, y: 45))
            NSColor(white: 0.85, alpha: 1).setStroke(); rule.lineWidth = 0.5; rule.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try? FileManager.default.removeItem(at: rawURL)
    print("wrote \(outURL.path) (\(total) pages)")
}

app.run()
