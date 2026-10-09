// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Generates MP4/M4V fixtures for exercising the metadata importer's success and
// failure paths by hand. Writes them to ./fixtures, which is safe to delete.
//
// The good files are real, playable H.264 MP4s carrying the same iTunes metadata
// atoms MetaParser reads (©nam, ©day, ©gen, ©cmt, desc, sonm, covr). The bad ones
// are files whose extension says MP4 but whose bytes do not, which is exactly what
// AVURLAsset refuses to open — the failure MetaParser.parseFile reports.

import Foundation
import AVFoundation
import AppKit
import CoreImage

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("fixtures")

// MARK: - Good files

/// Writes a minimal but genuinely valid H.264 MP4 carrying iTunes metadata.
func writeGoodFile(named name: String, title: String, year: Int,
                   genre: String, withArtwork: Bool) async throws {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)

    // .m4v, not .mp4: AVAssetWriter files metadata under the generic "org.mp4ra"
    // format for .mp4 output, and MetaParser only reads "com.apple.itunes". The
    // .m4v container is what produces the iTunes atoms — and is what the real files
    // this app imports are, since that is what iTunes-style taggers write. The
    // output extension is independent of this and is whatever the caller asked for.
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4v)

    func item(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol)
        -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = identifier
        m.value = value
        return m
    }

    var metadata: [AVMetadataItem] = [
        item(.iTunesMetadataSongName, title as NSString),
        item(.iTunesMetadataReleaseDate, "\(year)-06-15T12:00:00Z" as NSString),
        item(.iTunesMetadataUserGenre, genre as NSString),
        item(.iTunesMetadataUserComment, "Quality 85" as NSString),
        // Deliberately no description: AVFoundation's .iTunesMetadataDescription
        // writes the "©des" atom, while MetaParser reads "desc". Including it would
        // set an expectation the importer does not meet, which would read as an
        // importer bug during a manual test rather than the fixture quirk it is.
    ]

    if withArtwork {
        // A flat-colored 240x360 JPEG, so the poster-extraction branch runs too.
        let image = NSImage(size: NSSize(width: 240, height: 360))
        image.lockFocus()
        NSColor(calibratedHue: CGFloat(abs(title.hashValue % 100)) / 100.0,
                saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 240, height: 360).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [:]) {
            metadata.append(item(.iTunesMetadataCoverArt, jpeg as NSData))
        }
    }
    writer.metadata = metadata

    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 640,
        AVVideoHeightKey: 272,   // ~2.35:1, so the aspect-ratio snap has something to do
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)

    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 272, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
    if let pb = pixelBuffer {
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0x20,
               CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        // Two frames a second apart, so the file has a real, non-zero duration.
        for i in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
    await writer.finishWriting()
    if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

// MARK: - Bad files
// Each has an importable extension and unopenable contents. Verified: AVURLAsset
// throws "Cannot Open" on all four at the first `load(.availableMetadataFormats)`,
// which is the throw MetaParser.parseFile turns into a `.failure`.

func writeBadFiles() throws {
    let cases: [(String, Data)] = [
        ("bad-empty.mp4", Data()),
        ("bad-text-renamed.mp4", Data("this is not a video file at all\n".utf8)),
        ("bad-random-bytes.m4v", Data((0..<4096).map { _ in UInt8.random(in: 0...255) })),
        // Plausible-looking ftyp header with no usable atoms after it — the shape a
        // genuinely truncated download would have.
        ("bad-truncated.mp4", Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypisom".utf8)
            + Data([0x00, 0x00, 0x02, 0x00]) + Data("isomiso2avc1mp41".utf8)),
    ]
    for (name, data) in cases {
        try data.write(to: outDir.appendingPathComponent(name))
    }
}

// MARK: - Main

try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

try await writeGoodFile(named: "good-heat.mp4", title: "Heat", year: 1995,
                        genre: "Crime", withArtwork: true)
try await writeGoodFile(named: "good-solaris.m4v", title: "Solaris", year: 1972,
                        genre: "Science Fiction", withArtwork: true)
try await writeGoodFile(named: "good-no-artwork.mp4", title: "Stalker", year: 1979,
                        genre: "Drama", withArtwork: false)
try writeBadFiles()

// Two subfolders holding the exact selections each message needs, so a test run is
// one folder pick rather than a multi-select.
let partial = outDir.appendingPathComponent("selection-partial-failure")
let total = outDir.appendingPathComponent("selection-total-failure")
try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: total, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: outDir.appendingPathComponent("good-heat.mp4"),
                                 to: partial.appendingPathComponent("good-heat.mp4"))
try FileManager.default.copyItem(at: outDir.appendingPathComponent("bad-text-renamed.mp4"),
                                 to: partial.appendingPathComponent("bad-text-renamed.mp4"))
for f in ["bad-empty.mp4", "bad-text-renamed.mp4", "bad-truncated.mp4"] {
    try FileManager.default.copyItem(at: outDir.appendingPathComponent(f),
                                     to: total.appendingPathComponent(f))
}

// Verify each generated file really is what it claims to be, so a broken generator
// can't be mistaken for a broken importer.
print("Verifying fixtures against AVURLAsset (the check MetaParser performs first):\n")
var wrong = 0
for url in try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
    .filter({ ["mp4", "m4v"].contains($0.pathExtension) }).sorted(by: { $0.path < $1.path }) {
    let name = url.lastPathComponent
    let shouldOpen = name.hasPrefix("good-")
    var opened = false
    var detail = ""
    do {
        _ = try await AVURLAsset(url: url).load(.availableMetadataFormats)
        let d = try await AVURLAsset(url: url).load(.duration)
        opened = true
        detail = "duration \(String(format: "%.1f", d.seconds))s"
    } catch {
        detail = error.localizedDescription
    }
    let ok = opened == shouldOpen
    if !ok { wrong += 1 }
    print("  \(ok ? "✅" : "❌") \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) " +
          "\(opened ? "opens" : "refuses") — \(detail)")
}

print("""

Fixtures written to \(outDir.path)

  selection-partial-failure/  → 1 good + 1 bad  → "Some files failed to import."
  selection-total-failure/    → 3 bad           → "The import session failed."

Import a folder with Imports ▸ Metadata ▸ Select Files.
""")
if wrong > 0 {
    print("❌ \(wrong) fixture(s) did not behave as intended — do not test against these.")
    exit(1)
}
