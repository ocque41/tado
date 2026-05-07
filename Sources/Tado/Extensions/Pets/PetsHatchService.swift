import Foundation
import AppKit

/// Generates a custom pet sprite from a free-text prompt.
///
/// v1 contract — the **stub** implementation
/// - Renders a placeholder PNG: a cat-glyph background with the
///   first 24 chars of the prompt overlaid, plus a small "v1
///   stub" tag in the corner so it's obvious to the user that
///   real generation hasn't shipped yet.
/// - Writes the PNG to
///   `<storage-root>/pets/custom/<uuid>.apng` so the file
///   layout matches what v1.1 will produce. The custom-pet
///   picker reads from that directory.
///
/// v1.1+ contract — protocol-shaped so a real generator
/// (OpenAI Images, Anthropic, or a local sprite-diffuser) can
/// drop in by implementing `PetsHatchGenerator` and registering
/// itself on `PetsHatchService`. The slash command, MCP tool,
/// and on-disk path do not need to change.
public protocol PetsHatchGenerator: Sendable {
    /// Generate sprite frames for one pet. Implementations
    /// are expected to write a finished APNG to `outputURL`.
    func generate(prompt: String, outputURL: URL) async throws
}

@MainActor
public final class PetsHatchService {
    public static let shared = PetsHatchService()

    /// Live generator. nil when only the stub is installed.
    public var generator: (any PetsHatchGenerator)?

    private init() {}

    /// Hatch a new pet from the prompt. Returns the URL of the
    /// generated APNG. Throws on filesystem errors; the stub
    /// path itself never throws.
    public func requestHatch(prompt: String) async throws -> URL {
        let outputURL = try makeOutputURL()
        if let gen = generator {
            try await gen.generate(prompt: prompt, outputURL: outputURL)
        } else {
            try writeStubSprite(prompt: prompt, to: outputURL)
        }
        return outputURL
    }

    /// On-disk directory that holds custom hatched pets. The
    /// settings window's "Custom" tab enumerates this folder.
    public func customPetsDirectory() -> URL {
        StorageLocationManager.currentRoot
            .appendingPathComponent("pets", isDirectory: true)
            .appendingPathComponent("custom", isDirectory: true)
    }

    /// Import a user-supplied image sequence as a custom pet.
    ///
    /// Layout
    /// - One frame  → flat file: `<storage-root>/pets/custom/<id>.png`
    ///   (or `.apng` / `.gif` if the source is multi-frame).
    /// - Many frames → folder: `<storage-root>/pets/custom/<id>/`
    ///   with `frame-001.png` … `frame-NNN.png` plus a
    ///   `meta.json` carrying the original `name` and the
    ///   per-frame duration. The cache walks the folder in
    ///   sorted order and plays the frames as the loop.
    ///
    /// Returns the petID string (`custom:<id>`) so callers can
    /// drop it straight into `PetsPreferences.pet`.
    public func importImageSequence(
        from sourceURLs: [URL],
        name: String,
        frameDurationSeconds: Double = 0.12
    ) throws -> String {
        guard !sourceURLs.isEmpty else {
            throw NSError(
                domain: "PetsHatchService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No images provided"]
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = Self.sanitize(trimmedName.isEmpty ? "custom" : trimmedName)
        let baseDir = customPetsDirectory()
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Pick a non-colliding id by appending a digit if needed.
        var id = safeName
        var suffix = 2
        while FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(id).path)
            || FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("\(id).png").path)
            || FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("\(id).apng").path) {
            id = "\(safeName)-\(suffix)"
            suffix += 1
        }

        if sourceURLs.count == 1 {
            // Single image: keep the source extension if it's a
            // raster format we recognise; otherwise fall back to PNG.
            let src = sourceURLs[0]
            let ext = src.pathExtension.lowercased()
            let outExt = ["png", "apng", "gif", "jpeg", "jpg", "webp", "tiff"].contains(ext) ? ext : "png"
            let dest = baseDir.appendingPathComponent("\(id).\(outExt)")
            try FileManager.default.copyItem(at: src, to: dest)
        } else {
            // Many images: write a folder with `frame-NNN.<ext>`
            // ordered by the *input order* the caller chose, plus
            // a meta.json. The caller's order is the picker's
            // selection order, which preserves user intent.
            let folder = baseDir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (idx, src) in sourceURLs.enumerated() {
                let ext = src.pathExtension.lowercased()
                let outExt = ["png", "jpeg", "jpg", "webp", "tiff", "bmp", "heic"].contains(ext) ? ext : "png"
                let frameName = String(format: "frame-%03d.%@", idx + 1, outExt)
                try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(frameName))
            }
            let meta: [String: Any] = [
                "name": trimmedName,
                "frameDurationSeconds": frameDurationSeconds,
                "frameCount": sourceURLs.count
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try metaData.write(to: folder.appendingPathComponent("meta.json"), options: [.atomic])
        }

        return "custom:\(id)"
    }

    /// Import a per-state animation set. Writes the v2 layout:
    ///
    ///   <storage-root>/pets/custom/<id>/
    ///     meta.json          (version: 2 + states map + name)
    ///     states/
    ///       <state>/
    ///         frame-001.<ext>
    ///         frame-002.<ext>
    ///         …
    ///
    /// `sequences` keys are `PetState` raw values; missing states
    /// fall back at playback time to v1 single-sprite semantics
    /// inside `PetSpriteCache.loadCustom`. Empty arrays are
    /// skipped (do not write a state subdir for them). At least
    /// one non-empty state is required.
    ///
    /// Returns `custom:<id>` so callers can drop it straight into
    /// `PetsPreferences.pet`.
    public func importPerStateSequence(
        name: String,
        sequences: [PetState: [URL]],
        frameDurationSeconds: Double = 0.12
    ) throws -> String {
        let nonEmpty = sequences.filter { !$0.value.isEmpty }
        guard !nonEmpty.isEmpty else {
            throw NSError(
                domain: "PetsHatchService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Add at least one frame to one state before saving."]
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = Self.sanitize(trimmedName.isEmpty ? "custom" : trimmedName)
        let baseDir = customPetsDirectory()
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Pick a non-colliding id.
        var id = safeName
        var suffix = 2
        while FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(id).path)
            || FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("\(id).png").path)
            || FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("\(id).apng").path) {
            id = "\(safeName)-\(suffix)"
            suffix += 1
        }

        let petDir = baseDir.appendingPathComponent(id, isDirectory: true)
        let statesDir = petDir.appendingPathComponent("states", isDirectory: true)
        try FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)

        var statesMap: [String: String] = [:]
        for (state, urls) in nonEmpty {
            let stateDir = statesDir.appendingPathComponent(state.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            for (idx, src) in urls.enumerated() {
                let ext = src.pathExtension.lowercased()
                let outExt = ["png", "jpeg", "jpg", "webp", "tiff", "bmp", "heic", "gif", "apng"].contains(ext) ? ext : "png"
                let frameName = String(format: "frame-%03d.%@", idx + 1, outExt)
                try FileManager.default.copyItem(at: src, to: stateDir.appendingPathComponent(frameName))
            }
            statesMap[state.rawValue] = "states/\(state.rawValue)/"
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let meta: [String: Any] = [
            "name": trimmedName.isEmpty ? id : trimmedName,
            "version": 2,
            "frameDurationSeconds": frameDurationSeconds,
            "states": statesMap,
            "createdAt": now,
            "updatedAt": now
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try metaData.write(to: petDir.appendingPathComponent("meta.json"), options: [.atomic])

        return "custom:\(id)"
    }

    /// Strip path-unsafe characters from a user-typed pet name.
    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(
            name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        let collapsed = scrubbed.replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "pet" : String(trimmed.prefix(48)).lowercased()
    }

    // MARK: - Private

    private func makeOutputURL() throws -> URL {
        let dir = customPetsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).apng")
    }

    private func writeStubSprite(prompt: String, to url: URL) throws {
        // Draw directly into an NSBitmapImageRep with a custom
        // NSGraphicsContext so this works in headless test
        // environments (no AppKit run loop). Going through
        // NSImage.lockFocus / tiffRepresentation requires an
        // active window-server connection that the test target
        // doesn't have.
        let size = NSSize(width: 96, height: 96)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            throw NSError(
                domain: "PetsHatchService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate stub sprite bitmap"]
            )
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(
                domain: "PetsHatchService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context for stub sprite"]
            )
        }
        let prevContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = prevContext }

        // Background — soft purple gradient circle so the user
        // immediately sees this is a hatched pet, not a built-in.
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        NSColor(red: 0.45, green: 0.30, blue: 0.65, alpha: 1.0).setFill()
        path.fill()

        // Big cat glyph as the placeholder body.
        let glyph = NSAttributedString(
            string: "🐾",
            attributes: [
                .font: NSFont.systemFont(ofSize: 48),
                .foregroundColor: NSColor.white
            ]
        )
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(
            x: (size.width  - glyphSize.width)  / 2,
            y: (size.height - glyphSize.height) / 2 - 8
        ))

        // First 24 chars of the prompt at the bottom so the
        // result is identifiable.
        let label = String(prompt.prefix(24))
        let labelAttr = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
        )
        let labelSize = labelAttr.size()
        labelAttr.draw(at: NSPoint(
            x: (size.width - labelSize.width) / 2,
            y: 4
        ))

        // "v1 stub" tag, top-right.
        let stubAttr = NSAttributedString(
            string: "v1 stub",
            attributes: [
                .font: NSFont.systemFont(ofSize: 6, weight: .bold),
                .foregroundColor: NSColor.yellow
            ]
        )
        let stubSize = stubAttr.size()
        stubAttr.draw(at: NSPoint(
            x: size.width - stubSize.width - 4,
            y: size.height - stubSize.height - 2
        ))

        // Flush the context so the bitmap rep sees every draw
        // call before we encode it.
        context.flushGraphics()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "PetsHatchService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode stub sprite"]
            )
        }
        try pngData.write(to: url, options: [.atomic])
    }
}
