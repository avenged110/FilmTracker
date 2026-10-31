// MARK: - DBImporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Parses FilmTracker XML backup files and validates their structure.

import Foundation

public enum DBImporterError: Error {
    case fileNotFound(URL)
    case invalidXML(String)
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case missingRequiredElement(String)
    case corrupted(String)
}

/// Intermediate representation of a parsed object from XML.
/// @unchecked Sendable: properties contains [String: Any] which is not provably Sendable,
/// but ParsedObject is fully initialized before crossing actor boundaries and is never
/// mutated after transfer, making this safe.
public struct ParsedObject: @unchecked Sendable {
    public let exportID: String
    public let entityName: String
    public let properties: [String: Any]
    public let relationships: [String: [String]]
}

/// Container for a parsed backup file.
/// @unchecked Sendable: inherits the same [String: Any] constraint from ParsedObject.
public struct ParsedBackup: @unchecked Sendable {
    public let format: String
    public let version: Int
    public let createdISO8601: String
    public let appVersion: String?
    public let manifest: [String: Int]
    public let objects: [ParsedObject]
}

public final class DBImporter {
    /// Maximum XML file size accepted before parsing (512 MiB).
    /// Any backup larger than this is almost certainly malformed or malicious.
    private static let maxXMLFileSizeBytes: Int = 512 * 1024 * 1024

    public init() {}
    
    /// Parse and validate an XML backup file
    public func parseBackupFile(at url: URL) async throws -> ParsedBackup {
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw DBImporterError.fileNotFound(url)
        }

        // Enforce a size cap before loading to prevent OOM from a crafted file.
        if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           fileSize > Self.maxXMLFileSizeBytes {
            throw DBImporterError.corrupted(
                "Backup XML exceeds maximum allowed size (\(fileSize / (1024 * 1024)) MiB > 512 MiB)")
        }
        
        // Read file data
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DBImporterError.invalidXML("Could not read file: \(error.localizedDescription)")
        }
        
        // Parse XML
        let parser = BackupXMLParser()
        do {
            return try parser.parse(data: data)
        } catch let error as DBImporterError {
            throw error
        } catch {
            throw DBImporterError.invalidXML("XML parsing failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - XML Parser
fileprivate class BackupXMLParser: NSObject, XMLParserDelegate, Loggable {
    nonisolated static let logTag = "[DBImporter]"

    // MARK: - Parser Safety Limits
    // These caps prevent a crafted XML file from causing unbounded memory
    // allocation or pathological parse times. The limits are set well above
    // any realistic backup size (a 100 000-film library would be ~5 000 objects).
    //
    // maxObjectCount:      100 000 objects — generous ceiling for any real library.
    // maxElementDepth:     50 — the valid schema is 5 levels deep; 50 is a wide margin.
    // maxTextNodeBytes:    4 MiB per text node — notes fields are the largest payload.
    // maxRelationshipRefs: 10 000 refs per relationship — a list with 10 000 members.
    private static let maxObjectCount      = 100_000
    private static let maxElementDepth    = 50
    private static let maxTextNodeBytes   = 4 * 1024 * 1024  // 4 MiB
    private static let maxRelationshipRefs = 10_000

    private var parsedBackup: ParsedBackup?
    private var currentElement: String = ""
    private var currentAttributes: [String: String] = [:]
    private var currentText: String = ""
    
    // Root attributes
    private var format: String?
    private var version: Int?
    private var created: String?
    private var appVersion: String?
    
    // Manifest
    private var manifest: [String: Int] = [:]
    
    // Objects
    private var objects: [ParsedObject] = []
    private var currentObjectID: String?
    private var currentObjectEntity: String?
    private var currentProperties: [String: Any] = [:]
    private var currentRelationships: [String: [String]] = [:]
    private var currentPropertyName: String?
    private var currentRelationshipName: String?
    private var currentRelationshipRefs: [String] = []
    
    private var elementStack: [String] = []
    private var error: (any Error)?
    // Tracks whether the current property value was supplied via a CDATA section.
    // CDATA content must not be trimmed because leading/trailing whitespace is significant.
    private var currentPropertyHasCDATA: Bool = false
    // The value of the Property element's `type` attribute, when the writer supplied one.
    // Only "string" is currently emitted (see ExportedObject.propertyTypes). Absent for every
    // backup written before the attribute existed, in which case the inference path below is
    // used exactly as it always was.
    private var currentPropertyDeclaredType: String?
    
    func parse(data: Data) throws -> ParsedBackup {
        let parser = XMLParser(data: data)
        unsafe parser.delegate = self
        
        guard parser.parse() else {
            if let err = error {
                throw err
            }
            throw DBImporterError.invalidXML("XML parsing failed")
        }
        
        guard let backup = parsedBackup else {
            throw DBImporterError.invalidXML("Failed to construct backup structure")
        }
        
        return backup
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        // Enforce maximum nesting depth before pushing to the element stack.
        // A valid backup is at most 5 levels deep; exceeding the limit indicates
        // a malformed or malicious file.
        guard elementStack.count < Self.maxElementDepth else {
            if error == nil {
                error = DBImporterError.corrupted(
                    "XML nesting depth exceeds maximum (\(Self.maxElementDepth))")
            }
            parser.abortParsing()
            return
        }

        currentElement = elementName
        currentAttributes = attributeDict
        currentText = ""
        elementStack.append(elementName)
        
        switch elementName {
        case "FilmTrackerBackup":
            format = attributeDict["format"]
            if let vStr = attributeDict["version"], let v = Int(vStr) {
                version = v
            }
            created = attributeDict["created"]
            appVersion = attributeDict["appVersion"]
            
        case "Entity":
            if let name = attributeDict["name"],
               let countStr = attributeDict["count"],
               let count = Int(countStr) {
                manifest[name] = count
            }
            
        case "Object":
            // Enforce object count limit before starting to build a new object.
            guard objects.count < Self.maxObjectCount else {
                if error == nil {
                    error = DBImporterError.corrupted(
                        "Backup contains more than \(Self.maxObjectCount) objects")
                }
                parser.abortParsing()
                return
            }
            currentObjectID = attributeDict["id"]
            currentObjectEntity = attributeDict["entity"]
            currentProperties = [:]
            currentRelationships = [:]
            
        case "Property":
            currentPropertyName = attributeDict["name"]
            currentPropertyHasCDATA = false
            currentPropertyDeclaredType = attributeDict["type"]
            
        case "Relationship":
            currentRelationshipName = attributeDict["name"]
            currentRelationshipRefs = []
            
        case "Ref":
            // Enforce per-relationship reference count limit.
            guard currentRelationshipRefs.count < Self.maxRelationshipRefs else {
                if error == nil {
                    error = DBImporterError.corrupted(
                        "Relationship ref count exceeds maximum (\(Self.maxRelationshipRefs))")
                }
                parser.abortParsing()
                return
            }
            if let refID = attributeDict["id"] {
                currentRelationshipRefs.append(refID)
            }
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Guard against unbounded text accumulation from a crafted node.
        // UTF-8 byte count is a conservative proxy; .utf8.count is O(n) but
        // only runs while we are still under the limit.
        let incoming = string.utf8.count
        let existing  = currentText.utf8.count
        guard existing + incoming <= Self.maxTextNodeBytes else {
            if error == nil {
                error = DBImporterError.corrupted(
                    "Text node exceeds maximum size (\(Self.maxTextNodeBytes / (1024 * 1024)) MiB)")
            }
            parser.abortParsing()
            return
        }
        currentText += string
    }
    
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // Same size guard applied to CDATA sections.
        let incoming = CDATABlock.count
        let existing  = currentText.utf8.count
        guard existing + incoming <= Self.maxTextNodeBytes else {
            if error == nil {
                error = DBImporterError.corrupted(
                    "CDATA node exceeds maximum size (\(Self.maxTextNodeBytes / (1024 * 1024)) MiB)")
            }
            parser.abortParsing()
            return
        }
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += string
            currentPropertyHasCDATA = true
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !elementStack.isEmpty { elementStack.removeLast() }
        // Trim whitespace for regular text nodes only. CDATA content is never trimmed
        // because leading/trailing whitespace in notes, descriptions, etc. is intentional.
        let trimmed = currentPropertyHasCDATA ? currentText : currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch elementName {
        case "Property":
            if let propName = currentPropertyName {
                if currentPropertyDeclaredType == "string" {
                    // The writer stated that this field is a String in the model, so there is
                    // nothing to infer. Taking the text verbatim is what preserves values
                    // whose content merely LOOKS like another type — "007", "2.00", "true",
                    // "[\"a\",\"b\"]" — each of which the inference below would convert to a
                    // different type, and which the restore would then either reformat or,
                    // for the boolean and array shapes, fail to convert back at all and
                    // replace with an empty string.
                    currentProperties[propName] = trimmed
                } else {
                    currentProperties[propName] = parsePropertyValue(trimmed)
                }
            }
            currentPropertyName = nil
            currentPropertyHasCDATA = false
            currentPropertyDeclaredType = nil
            
        case "Relationship":
            if let relName = currentRelationshipName {
                currentRelationships[relName] = currentRelationshipRefs
            }
            currentRelationshipName = nil
            currentRelationshipRefs = []
            
        case "Object":
            if let objID = currentObjectID,
               let entity = currentObjectEntity {
                let parsed = ParsedObject(
                    exportID: objID,
                    entityName: entity,
                    properties: currentProperties,
                    relationships: currentRelationships
                )
                objects.append(parsed)
            }
            currentObjectID = nil
            currentObjectEntity = nil
            
        case "FilmTrackerBackup":
            // Validate required fields
            guard let fmt = format else {
                error = DBImporterError.missingRequiredElement("format attribute")
                parser.abortParsing()
                return
            }
            guard let ver = version else {
                error = DBImporterError.missingRequiredElement("version attribute")
                parser.abortParsing()
                return
            }
            guard let crt = created else {
                error = DBImporterError.missingRequiredElement("created attribute")
                parser.abortParsing()
                return
            }
            
            // Validate format
            if fmt != "FilmTrackerXML" {
                error = DBImporterError.unsupportedFormat(fmt)
                parser.abortParsing()
                return
            }
            
            // Validate version
            if ver > 1 {
                error = DBImporterError.unsupportedVersion(ver)
                parser.abortParsing()
                return
            }
            
            parsedBackup = ParsedBackup(
                format: fmt,
                version: ver,
                createdISO8601: crt,
                appVersion: appVersion,
                manifest: manifest,
                objects: objects
            )
            
        default:
            break
        }
        
        currentText = ""
    }
    
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        if error == nil {
            error = DBImporterError.invalidXML("Parse error: \(parseError.localizedDescription)")
        }
    }
    
    // MARK: - Property Value Parsing
    
    private func parsePropertyValue(_ string: String) -> Any {
        // Handle empty/null
        if string.isEmpty {
            return NSNull()
        }
        
        // Handle booleans
        if string == "true" { return true }
        if string == "false" { return false }

        // Handle JSON arrays (must be valid JSON array syntax, not just any string with brackets)
        // Real JSON arrays of strings either:
        // 1. Are empty: []
        // 2. Contain quotes: ["item1", "item2"]
        // This prevents plain strings like "[REC]" from being incorrectly parsed as arrays.
        let looksLikeArray = string.hasPrefix("[") && string.hasSuffix("]")
        let isEmptyArray = string == "[]"
        let hasQuotes = string.contains("\"")
        
        if looksLikeArray && (isEmptyArray || hasQuotes) {
            // Decode the text EXACTLY as XMLParser handed it over.
            //
            // XMLParser has already resolved every entity reference in the document, so the
            // string reaching this point is the writer's JSON verbatim. Running xmlUnescape
            // over it — as this branch used to, unconditionally — is a SECOND unescape, and
            // it rewrites any array element whose own content contains an entity-shaped
            // literal. "Tom &amp; Jerry" came back as "Tom & Jerry"; "&lt;REC&gt;" as
            // "<REC>"; and "He said &quot;hi&quot;" produced quotes that broke the JSON
            // outright, so the decode failed and the WHOLE field was restored empty.
            //
            // The unescaped form is kept only as a FALLBACK, tried after the verbatim decode
            // fails. That preserves any hypothetical backup whose arrays really were written
            // double-escaped, while making a correctly written one round-trip exactly.
            let decodeArray: (String) -> [String]? = { candidate in
                guard let data = candidate.data(using: .utf8) else { return nil }
                if let arr = try? JSONDecoder().decode([String].self, from: data) {
                    return arr
                }
                // FALLBACK ONLY — never attempted before the verbatim decode above.
                //
                // Handles backslash-escaped apostrophes from upstream metadata: patterns
                // like D\'Onofrio are invalid JSON (JSON has no \' escape sequence). This
                // affects ~147 films with actor names containing apostrophes.
                //
                // It runs SECOND for the same reason the xmlUnescape fallback below does.
                // Applied first — as it used to be — it corrupted the healthy case to
                // rescue the broken one: JSONEncoder writes a literal backslash as `\\`, so
                // an element genuinely containing a backslash before an apostrophe produces
                // the valid JSON `["D\\'Onofrio"]`, which CONTAINS the two-character
                // sequence `\'`. The cleanup matched inside that `\\'`, rewrote it to `\'`,
                // and turned valid JSON invalid — the decode then failed and the WHOLE field
                // was restored empty, losing an entire cast list to one apostrophe.
                //
                // Ordering it second costs the legacy case nothing: genuinely malformed
                // `D\'Onofrio` text fails the verbatim decode and reaches this line exactly
                // as before. Correctly written JSON now never reaches it at all.
                guard candidate.contains("\\'") else { return nil }
                let cleaned = candidate.replacingOccurrences(of: "\\'", with: "'")
                guard let cleanedData = cleaned.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode([String].self, from: cleanedData)
            }

            if let arr = decodeArray(string) {
                return arr
            }
            let unescaped = xmlUnescape(string)
            if unescaped != string, let arr = decodeArray(unescaped) {
                Self.log("NOTE: Array decoded only after XML unescaping — backup appears to be double-escaped: \(string.prefix(100))")
                return arr
            }
            // If JSON decode fails, return NSNull (which SafeValueParser.parseStringArray
            // maps to an empty array) rather than the raw string. Returning the raw string
            // is worse: parseStringArray would wrap it as a single-element array containing
            // the corrupt literal (e.g. the description-form string "[\"\\u{01}\"]"),
            // inserting garbage into the restored database. Silently restoring as empty is
            // preferable to persisting corrupt data; the warning still surfaces in the log.
            Self.log("WARNING: Failed to decode array from: \(string.prefix(100)). Restoring as empty array.")
            return NSNull()
        }
        
        // Handle numbers (before UUID check to avoid false positives)
        if let int64 = Int64(string) {
            return int64
        }
        if let double = Double(string) {
            return double
        }
        
        // Handle UUID strings - validate format to ensure they're proper UUIDs
        // UUID format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (36 characters with 4 hyphens)
        if string.count == 36 && string.filter({ $0 == "-" }).count == 4 {
            // This looks like a UUID, validate and normalize it
            if let uuid = UUID(uuidString: string) {
                // Return the normalized UUID string (uppercase with proper format)
                return uuid.uuidString
            }
            // If it looks like a UUID but can't be parsed, return as-is (will fail later with better error)
            return string
        }
        
        // Handle legacy array format (for backward compatibility)
        if string.hasPrefix("<Array>") && string.hasSuffix("</Array>") {
            return parseArrayValue(string)
        }
        
        // Default to string
        return string
    }
    
    private func parseArrayValue(_ string: String) -> [String] {
        // Legacy array format cap — matches the JSON array path's implicit upper
        // bound via the object count limit (each film's arrays are bounded in practice,
        // but we enforce a hard ceiling here as a defense-in-depth measure).
        let maxItems = 10_000
        var result: [String] = []
        let content = string
            .replacingOccurrences(of: "<Array>", with: "")
            .replacingOccurrences(of: "</Array>", with: "")
        
        // Simple regex-free parsing
        var current = content
        while let startRange = current.range(of: "<Item>"),
              let endRange = current.range(of: "</Item>") {
            guard result.count < maxItems else {
                Self.log("WARNING: Legacy array truncated at \(maxItems) items")
                break
            }
            let itemStart = startRange.upperBound
            let itemEnd = endRange.lowerBound
            if itemStart < itemEnd {
                let item = String(current[itemStart..<itemEnd])
                result.append(xmlUnescape(item))
            }
            current = String(current[endRange.upperBound...])
        }
        
        return result
    }
    
    private func xmlUnescape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}

// DBImporter has no stored mutable state, so Sendable (not @unchecked) is correct.
// ParsedObject and ParsedBackup conformances are declared inline above.
extension DBImporter: Sendable {}
