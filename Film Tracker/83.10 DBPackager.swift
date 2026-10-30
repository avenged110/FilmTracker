// MARK: - DBPackager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Sandbox-only streaming writer for packaging DBReader.swift output as an XML file.

import Foundation

public enum DBPackagerError: Error {
    case cannotCreateDirectory(URL)
    case writeFailed(URL, underlying: any Error)
}

public final class DBPackager: Loggable {
    // Public for the same reason as DBExporter.logTag — see the note there.
    nonisolated public static let logTag = "[DBPackager]"

    // No formatter or encoder is held here any more: dates and arrays are serialized by
    // DBReader before they reach this file (see encodeXmlPropertyValue), so the packager
    // only ever writes text it has been handed.

    public init() {}

    // Determine the backup folder to use.
    public func backupsFolder() throws -> URL {
        let fm = FileManager.default
        // Retrieve user-configured backup folder from Preferences
        guard let folder = Preferences.backupFolderURL else {
            Self.log("WARNING: No backup folder configured in Preferences")
            throw DBPackagerError.cannotCreateDirectory(URL(fileURLWithPath: "")) }
        // Verify it exists or can be created
        do {
            try fm.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: nil)
        } catch {
            Self.log("WARNING: Could not create backup folder at \(folder.path(percentEncoded: false)): \(error.localizedDescription)")
            throw DBPackagerError.cannotCreateDirectory(folder) }
        return folder }

    // Stream the ExportPackage into a file in the chosen backup folder.
    // - Returns: URL to the final file inside the chosen folder (atomic move from temp file).
    public func package(exportPackage: ExportPackage, filename: String, folderURL: URL? = nil,
        isBackgroundExport: Bool = false,
        progress: ((Double) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()

        // Use provided folder, otherwise Preferences.backupFolderURL (validated).
        let folder = try folderURL ?? backupsFolder()
        let fm = FileManager.default

        Self.log("Packaging '\(filename)' into \(folder.lastPathComponent) (\(exportPackage.objects.count) object(s))")

        let tempFilename = filename + ".tmp-\(UUID().uuidString)"
        let tempURL = folder.appendingPathComponent(tempFilename)
        let finalURL = folder.appendingPathComponent(filename)

        // Create empty temporary file.
        fm.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil, attributes: nil)

        // Open the file for writing.
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forWritingTo: tempURL)
            try fileHandle.truncate(atOffset: 0)
        } catch {
            Self.log("WARNING: Failed to open temp file for writing at \(tempURL.lastPathComponent): \(error.localizedDescription)")
            try? fm.removeItem(at: tempURL)
            throw DBPackagerError.writeFailed(tempURL, underlying: error) }

        func write(_ s: String) throws {
            try Task.checkCancellation()
            guard let data = s.data(using: .utf8) else { return }
            try fileHandle.write(contentsOf: data) }

        // Shared cleanup used by every error path below. Closes the file handle and
        // removes the temp file, then rethrows — CancellationError is passed through
        // unwrapped so callers can distinguish cancellation (`catch is CancellationError`)
        // from genuine write failure. Any other error is wrapped as
        // DBPackagerError.writeFailed.
        func cleanupAndRethrow(_ error: any Error) throws -> Never {
            try? fileHandle.close()
            try? fm.removeItem(at: tempURL)
            if error is CancellationError {
                Self.log("NOTE: Packaging of '\(filename)' was canceled")
                throw error
            }
            Self.log("WARNING: Packaging of '\(filename)' failed: \(error.localizedDescription)")
            throw DBPackagerError.writeFailed(tempURL, underlying: error)
        }

        let manifestWeight = 0.05
        let objectsWeight = 1.0 - manifestWeight

        // Header + root start.
        do {
            let header = """
            <?xml version="1.0" encoding="utf-8"?>
            <!-- FilmTracker Backup file. Format key: FilmTrackerXML -->
            """
            try write(header + "\n")

            let rootAttrs = [
                "format": exportPackage.format,
                "version": String(exportPackage.version),
                "created": exportPackage.createdISO8601,
                "appVersion": exportPackage.appVersion ?? "" ]
            let attrPairs = rootAttrs.compactMap { (k, v) -> String? in
                guard !v.isEmpty else { return nil }
                return "\(k)=\"\(xmlEscape(v))\""
            }.joined(separator: " ")
            try write("<FilmTrackerBackup \(attrPairs)>\n")
        } catch {
            try cleanupAndRethrow(error) }

        // Manifest.
        do {
            try write("  <Manifest>\n")
            for (entity, count) in exportPackage.manifest.sorted(by: { $0.key < $1.key }) {
                try write("    <Entity name=\"\(xmlEscape(entity))\" count=\"\(count)\" />\n") }
            try write("  </Manifest>\n\n")
            progress?(manifestWeight * 0.5)
        } catch {
            try cleanupAndRethrow(error) }

        // Objects.
        do {
            try write("  <Objects>\n")
        } catch {
            try cleanupAndRethrow(error) }

        let totalObjects = exportPackage.objects.count

        // For background exports, yield periodically during write operations
        let yieldInterval = isBackgroundExport ? 25 : 100
        
        for (index, obj) in exportPackage.objects.enumerated() {
            do {
                try Task.checkCancellation()
                try write("    <Object id=\"\(xmlEscape(obj.exportID))\" entity=\"\(xmlEscape(obj.entityName))\">\n")
                try write("      <Properties>\n")
                for (k, anyCod) in obj.properties.sorted(by: { $0.key < $1.key }) {
                    let valStr = encodeXmlPropertyValue(anyCod, declaredType: obj.propertyTypes[k])
                    // The declared-type attribute, written only where DBReader recorded one
                    // (String-typed values). Readers that predate it ignore it; readers that
                    // honor it skip the type inference that would otherwise misread a
                    // string whose content looks numeric, boolean, or array-shaped.
                    let typeAttr = obj.propertyTypes[k].map { " type=\"\(xmlEscape($0))\"" } ?? ""
                    try write("        <Property name=\"\(xmlEscape(k))\"\(typeAttr)>\(valStr)</Property>\n") }
                try write("      </Properties>\n")
                try write("      <Relationships>\n")
                for (relName, ids) in obj.relationships.sorted(by: { $0.key < $1.key }) {
                    try write("        <Relationship name=\"\(xmlEscape(relName))\">\n")
                    for rid in ids {
                        try write("          <Ref id=\"\(xmlEscape(rid))\" />\n") }
                    try write("        </Relationship>\n") }
                try write("      </Relationships>\n")
                try write("    </Object>\n")
            } catch {
                try cleanupAndRethrow(error) }

            let objectsProgress = objectsWeight * (Double(index + 1) / Double(totalObjects))
            let totalProgress = manifestWeight + objectsProgress
            progress?(totalProgress)
            
            // Yield periodically for background exports
            if isBackgroundExport && (index + 1) % yieldInterval == 0 {
                try? await Task.sleep(for: .milliseconds(1)) // 1ms yield
            }
        }

        // Close the file and move it atomically.
        do {
            try write("  </Objects>\n")
            try write("</FilmTrackerBackup>\n")
            try fileHandle.close()
            if fm.fileExists(atPath: finalURL.path(percentEncoded: false)) { try fm.removeItem(at: finalURL) }
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            try cleanupAndRethrow(error) }

        progress?(1.0)
        Self.log("Packaging complete: '\(filename)' written with \(totalObjects) object(s)")
        return finalURL }

    // MARK: - Helpers

    fileprivate func xmlEscape(_ s: String) -> String {
        var out = s.strippingIllegalXMLScalars
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out }

    // Wraps a string in a CDATA section, guaranteeing the result is valid XML:
    //   • Illegal XML 1.0 scalars are stripped first — a raw CDATA section cannot
    //     legally contain them, so the previous (unstripped) CDATA path could emit
    //     an unparseable file for any string that held both a control character and
    //     an XML special character.
    //   • Any embedded "]]>" sequence is split across two CDATA sections. Without this
    //     an embedded "]]>" (which can occur in free-text fields such as notes, or in
    //     a JSON-encoded array element) would terminate the CDATA section early and
    //     corrupt the entire backup. On read, XMLParser concatenates the two adjacent
    //     CDATA blocks back into the original "]]>" so the round-trip is exact.
    fileprivate func wrapInCDATA(_ s: String) -> String {
        let safe = s.strippingIllegalXMLScalars
            .replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        return "<![CDATA[\(safe)]]>"
    }


    /// - Parameter declaredType: the model's declared type for this property when the reader
    ///   recorded one (see `ExportedObject.propertyTypes`); `nil` for every value whose type
    ///   is recoverable from its text, and for backups' sake, for genuine UUID properties.
    fileprivate func encodeXmlPropertyValue(_ anyCodable: AnyCodable,
                                            declaredType: String? = nil) -> String {
        let val = anyCodable.value
        
        // Handle NSNull first
        if val is NSNull {
            return ""
        }
        
        // NOTE ON THE TYPES THIS FUNCTION HANDLES
        //
        // `DBReader.exportAll` is the ONLY producer of the AnyCodable values that reach
        // here — ExportPackage is never decoded from anywhere, so nothing else can inject a
        // value — and it normalizes as it builds `propsEncoded`. By the time a value
        // arrives it is one of exactly five things: NSNull, String, Bool, Int64 or Double.
        //
        // Three branches for UUID, [String] and Date used to sit here as "defensive"
        // duplicates. They were unreachable, and what they were defending is already done
        // upstream, better:
        //   • UUID   → the reader writes `uuid.uuidString` and records NO declared type, so
        //              the String branch's own normalization below still canonicalizes it.
        //   • [String] → the reader strips XML-illegal scalars and THEN JSON-encodes; this
        //              copy did neither, so it was the weaker of the two.
        //   • Date   → the reader formats with the shared ISO8601 formatter, configured
        //              identically to this file's; the two produced the same string.
        // The final `String(describing:)` fallback remains as the genuine backstop for a
        // value shape the reader might grow later.

        // Handle strings
        if let s = val as? String {
            // NO `\'` CLEANUP HERE — it can only ever damage what it touches.
            //
            // A `replacingOccurrences(of: "\\'", with: "'")` used to run on every string
            // reaching this point, described as cleaning up backslash-escaped apostrophes
            // from upstream metadata. That cleanup belongs on the READ side, and it is
            // already there and correct: DBImporter's `decodeArray` applies it to legacy
            // files whose arrays really do carry the invalid `\'` escape (D\'Onofrio and
            // friends). Applied HERE, to values on their way OUT, it had no legacy input to
            // repair and two ways to corrupt a healthy one:
            //
            //   • A String field — declared type "string" — whose text genuinely contains a
            //     backslash before an apostrophe (a Windows path, a shell-quoted fragment)
            //     was written to the backup with the backslashes silently removed. The
            //     restore has nothing to recover them from; the loss is permanent.
            //
            //   • A [String] field arrives here as JSON that DBReader produced with
            //     JSONEncoder, so a literal backslash is already encoded as `\\`. The
            //     cleanup matched the `\'` inside that `\\'` and rewrote it to `\'` —
            //     which is not a legal JSON escape. The array then failed to decode on
            //     restore and DBImporter substituted NSNull, so the WHOLE field came back
            //     empty: an entire cast list lost to one apostrophe.
            //
            // JSONEncoder output is always valid JSON, and a declared String must be
            // written verbatim, so there is no value shape the cleanup could have helped.
            // This is the same defect class as the UUID normalization immediately below,
            // which is why that one is gated on `declaredType` rather than deleted — it
            // has a real job to do for genuine UUID properties. This one had none.
            let cleanString = s

            // Check if it's a UUID string - if so, validate and normalize it.
            //
            // Skipped for a value the model declares as a String. The normalization exists for
            // genuine UUID PROPERTIES (id, filmID, listID, parentReleaseID), which DBReader
            // converts to strings before they arrive here and which must be canonically
            // formatted so the restore's lookups match. Applying it to a text field instead
            // rewrites the user's data: any String field holding a UUID-shaped value came back
            // upper-cased. That is visible corruption in a free-text field, and `posterUID` is
            // a String field whose value names a file on disk — upper-casing it there breaks
            // the link between a film and its poster image.
            if declaredType != "string", isUUIDString(cleanString) {
                // Validate and normalize UUID format
                if let uuid = UUID(uuidString: cleanString) {
                    return xmlEscape(uuid.uuidString)
                }
                // If invalid UUID format, still write it but it will fail on import
                return xmlEscape(cleanString)
            }
            
            // Use CDATA for strings containing XML special characters, and for strings whose
            // leading or trailing whitespace is significant.
            //
            // The whitespace case is not cosmetic: the reader trims every non-CDATA property
            // value (it cannot distinguish a value's own padding from XML formatting), so
            // "  padded  " came back as "padded" and a description ending in a space lost it.
            // CDATA is the signal the reader already honors for exactly this — it is the one
            // branch that is never trimmed — so routing padded strings through it fixes the
            // loss with no format change and no effect on any other reader.
            //
            // A JSON-encoded array can never take this branch: JSONEncoder output begins with
            // "[" and ends with "]", so array values keep being written as escaped text and
            // keep being reconstructed as arrays.
            let hasSignificantWhitespace =
                cleanString != cleanString.trimmingCharacters(in: .whitespacesAndNewlines)
            // A carriage return goes through CDATA too: in plain text the parser normalizes
            // "\r\n" and a lone "\r" to "\n" (XML end-of-line handling), so notes pasted
            // with Windows line endings lost them, while CDATA hands "\r" back intact.
            if cleanString.contains("<") || cleanString.contains("&") || cleanString.contains(">")
                || cleanString.contains("\r") || hasSignificantWhitespace {
                return wrapInCDATA(cleanString)
            } else {
                return xmlEscape(cleanString)
            }
        }
        
        // Handle booleans
        if let b = val as? Bool {
            return b ? "true" : "false"
        }
        
        // Handle numbers
        if let n = val as? Int64 {
            return String(n)
        }
        if let n = val as? Int {
            return String(n)
        }
        if let n = val as? Double {
            return String(n)
        }
        
        // Fallback for any other type
        return xmlEscape(String(describing: val))
    }

    private func isUUIDString(_ s: String) -> Bool {
        // UUID format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (36 characters with 4 hyphens)
        return s.count == 36 && s.filter({ $0 == "-" }).count == 4
    }
}

extension DBPackager: Sendable {}
