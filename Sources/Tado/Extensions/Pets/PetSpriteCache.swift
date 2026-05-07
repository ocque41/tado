import Foundation
import AppKit

/// One frame of an APNG sprite — a `NSImage` plus the time it
/// should stay on screen before the next frame.
public struct PetSpriteFrame: Equatable {
    public let image: NSImage
    public let duration: TimeInterval
}

/// Loads pet APNG sprites from `Bundle.module/Resources/Pets/` and
/// keeps decoded frame arrays cached in memory.
///
/// One sprite is identified by `(petID, state)`. Filenames follow
/// `Resources/Pets/<petID>-<state>.apng`. Files are read once on
/// first access; the result lives in a process-wide cache for the
/// rest of the app's lifetime. ~24-40 sprites × ~30 KB each =
/// well under 1 MB even fully populated.
///
/// **Why `NSBitmapImageRep`** — AppKit decodes APNG natively on
/// macOS 14+ (Tado's min target). Frame count and per-frame
/// duration are exposed as image properties; reading them avoids
/// the need for a third-party APNG decoder.
///
/// **Resilience** — if a sprite file is missing, returns a
/// single-frame static glyph fallback instead of crashing. This
/// matters because v1 ships placeholder PNGs that may not yet
/// exist in every (pet, state) combination — the fallback keeps
/// the sprite view rendering something rather than going blank.
@MainActor
public final class PetSpriteCache {
    public static let shared = PetSpriteCache()

    private var cache: [String: [PetSpriteFrame]] = [:]
    /// Per-pet glyph used by the fallback when no APNG ships
    /// for the (pet, state) pair. Picked to match Codex Pets'
    /// roster so the picker is recognisable from the get-go.
    private static let petGlyph: [String: String] = [
        "cat":     "🐱",
        "dog":     "🐶",
        "fox":     "🦊",
        "owl":     "🦉",
        "crab":    "🦀",
        "snake":   "🐍",
        "octopus": "🐙",
        "dragon":  "🐲"
    ]
    /// Per-state accent emoji painted in a corner badge so
    /// fallback sprites still convey what the pet is doing.
    private static let stateBadge: [PetState: String] = [
        .idle:             "💤",
        .done:             "✅",
        .running:          "⚙️",
        .needsInput:       "👀",
        .awaitingResponse: "❓",
        .eternalRunning:   "♾️",
        .perfRegressed:    "⚠️"
    ]
    /// Per-state background accent. Keeps fallbacks visually
    /// distinct between states even when the same pet is in
    /// every state.
    private static let stateBackground: [PetState: NSColor] = [
        .idle:             NSColor(white: 0.22, alpha: 1.0),
        .done:             NSColor(red: 0.15, green: 0.50, blue: 0.30, alpha: 1.0),
        .running:          NSColor(red: 0.18, green: 0.42, blue: 0.65, alpha: 1.0),
        .needsInput:       NSColor(red: 0.25, green: 0.40, blue: 0.65, alpha: 1.0),
        .awaitingResponse: NSColor(red: 0.65, green: 0.50, blue: 0.20, alpha: 1.0),
        .eternalRunning:   NSColor(red: 0.45, green: 0.30, blue: 0.65, alpha: 1.0),
        .perfRegressed:    NSColor(red: 0.65, green: 0.25, blue: 0.25, alpha: 1.0)
    ]

    private init() {}

    /// Frame array for `(petID, state)`. Decodes lazily; result is cached.
    public func frames(petID: String, state: PetState) -> [PetSpriteFrame] {
        let key = "\(petID)-\(state.rawValue)"
        if let cached = cache[key] { return cached }

        let frames: [PetSpriteFrame]

        if petID.hasPrefix("custom:") {
            // Custom pets live under <storage-root>/pets/custom/.
            // Two layouts supported:
            // 1. Flat file: `<id>.png` / `<id>.apng` / `<id>.gif`
            //    — single sprite reused for every state.
            // 2. Folder: `<id>/frame-001.png` ... `frame-NNN.png`
            //    plus an optional `meta.json` with a
            //    `frameDurationSeconds` value. Multi-frame
            //    animation; loaded as a sequence.
            // Both are pet-level, not per-state, so the same
            // sprite plays in every state.
            let stem = String(petID.dropFirst("custom:".count))
            frames = Self.loadCustom(stem: stem)
                ?? Self.fallback(for: state, petID: petID)
        } else if let url = Bundle.module.url(
            forResource: "\(petID)-\(state.rawValue)",
            withExtension: "apng",
            subdirectory: "Resources/Pets"
        ) ?? Bundle.module.url(
            // Some bundles strip the subdirectory layer in
            // release builds; try the flat layout as a backup.
            forResource: "\(petID)-\(state.rawValue)",
            withExtension: "apng"
        ) {
            frames = Self.decodeAPNG(at: url) ?? Self.fallback(for: state, petID: petID)
        } else {
            frames = Self.fallback(for: state, petID: petID)
        }

        cache[key] = frames
        return frames
    }

    // MARK: - Custom pet loading

    private static func loadCustom(stem: String) -> [PetSpriteFrame]? {
        let root = StorageLocationManager.currentRoot
            .appendingPathComponent("pets", isDirectory: true)
            .appendingPathComponent("custom", isDirectory: true)
        let folderURL = root.appendingPathComponent(stem, isDirectory: true)

        // Layout 2: folder of frame-NNN.<ext>.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir),
           isDir.boolValue {
            return loadCustomFolder(folderURL)
        }

        // Layout 1: flat file. Try common extensions.
        for ext in ["apng", "png", "gif", "jpeg", "jpg", "webp"] {
            let fileURL = root.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if ext == "apng" || ext == "png" || ext == "gif" {
                    if let frames = decodeAPNG(at: fileURL), !frames.isEmpty {
                        return frames
                    }
                }
                if let nsImage = NSImage(contentsOf: fileURL) {
                    return [PetSpriteFrame(image: nsImage, duration: 0.5)]
                }
            }
        }
        return nil
    }

    private static func loadCustomFolder(_ folder: URL) -> [PetSpriteFrame]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return nil }

        // Read optional meta.json for per-frame duration.
        var duration: TimeInterval = 0.12
        let metaURL = folder.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = json["frameDurationSeconds"] as? Double, d > 0 {
            duration = d
        }

        let imageExts: Set<String> = ["png", "jpeg", "jpg", "webp", "tiff", "bmp", "heic"]
        let imageFiles = entries
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !imageFiles.isEmpty else { return nil }

        var frames: [PetSpriteFrame] = []
        frames.reserveCapacity(imageFiles.count)
        for url in imageFiles {
            if let img = NSImage(contentsOf: url) {
                frames.append(PetSpriteFrame(image: img, duration: duration))
            }
        }
        return frames.isEmpty ? nil : frames
    }

    /// Pre-warm the cache for one pet so the first sprite swap
    /// doesn't take a sync decode hit. Cheap; called once when
    /// the panel goes visible.
    public func preheat(petID: String) {
        for state in PetState.allCases {
            _ = frames(petID: petID, state: state)
        }
    }

    /// Drop any cached frames whose pet id is the argument. Used
    /// when the user picks a new pet so we reclaim ~120-200 KB.
    public func evict(petID: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(petID)-") }
    }

    // MARK: - APNG decode

    private static func decodeAPNG(at url: URL) -> [PetSpriteFrame]? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }

        // `NSImageFrameCount` is set by the APNG decoder; static
        // PNGs report 1 (or no key, which is how we treat it).
        let frameCountValue = rep.value(forProperty: .frameCount) as? Int
        let frameCount = max(1, frameCountValue ?? 1)

        var frames: [PetSpriteFrame] = []
        frames.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            rep.setProperty(.currentFrame, withValue: i)
            // `NSImageCurrentFrameDuration` is in seconds. APNG
            // files often encode 0 here for "use sender default";
            // clamp to 0.04s (~24fps) so we never spin a 0-tick
            // animation timer at wall-clock speed.
            let raw = (rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
            let duration = raw > 0 ? raw : 0.1

            guard let frameImage = Self.flattenFrame(rep) else { continue }
            frames.append(PetSpriteFrame(image: frameImage, duration: duration))
        }
        return frames.isEmpty ? nil : frames
    }

    /// Take one frame of an APNG-aware `NSBitmapImageRep` and
    /// produce a freshly-allocated single-frame `NSImage` so
    /// SwiftUI can switch between frames without all of them
    /// pointing at the same shared rep.
    private static func flattenFrame(_ rep: NSBitmapImageRep) -> NSImage? {
        guard let cgImage = rep.cgImage else { return nil }
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let copy = NSBitmapImageRep(cgImage: cgImage)
        copy.size = size
        let image = NSImage(size: size)
        image.addRepresentation(copy)
        return image
    }

    // MARK: - Fallback

    /// Construct a fallback animation when an APNG file is
    /// missing. The sprite combines a pet glyph (cat/dog/...) with
    /// a state-coloured background and a small badge in the corner
    /// so the user can still tell at a glance what's happening.
    /// We render four frames with a subtle bob animation so the
    /// sprite *moves* — important for the "alive companion"
    /// experience even on a fresh install with no shipped art.
    private static func fallback(for state: PetState, petID: String) -> [PetSpriteFrame] {
        let bg = stateBackground[state] ?? NSColor(white: 0.22, alpha: 1.0)
        let petString = petGlyph[petID] ?? "🐾"
        let badgeString = stateBadge[state] ?? ""

        // Custom pets coming from `<storage-root>/pets/custom/`
        // use the URL filename as their petID. Don't try to draw
        // a glyph on top of those — the file *is* the sprite.
        // Caller path (frames(petID:state:)) already handles the
        // file-loading branch; we only get here when the URL
        // didn't resolve, so a plain pet face is fine.

        var frames: [PetSpriteFrame] = []
        for offset in [CGFloat(0), 1, 2, 1] {
            let image = renderFallbackFrame(
                bg: bg,
                pet: petString,
                badge: badgeString,
                bobOffset: offset
            )
            frames.append(PetSpriteFrame(image: image, duration: 0.18))
        }
        return frames
    }

    private static func renderFallbackFrame(
        bg: NSColor,
        pet: String,
        badge: String,
        bobOffset: CGFloat
    ) -> NSImage {
        let size = NSSize(width: 96, height: 96)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Filled circle background.
        let inset: CGFloat = 4
        bg.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: inset, y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )).fill()

        // Subtle white inner-stroke ring.
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: inset + 1, y: inset + 1,
            width: size.width - inset * 2 - 2,
            height: size.height - inset * 2 - 2
        ))
        ring.lineWidth = 1.0
        ring.stroke()

        // Pet glyph centered, bobbing.
        let petAttr = NSAttributedString(
            string: pet,
            attributes: [
                .font: NSFont.systemFont(ofSize: 50),
                .foregroundColor: NSColor.white
            ]
        )
        let petSize = petAttr.size()
        petAttr.draw(at: NSPoint(
            x: (size.width  - petSize.width)  / 2,
            y: (size.height - petSize.height) / 2 - 6 + bobOffset
        ))

        // State badge top-right.
        if !badge.isEmpty {
            let badgeAttr = NSAttributedString(
                string: badge,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 18)
                ]
            )
            let badgeSize = badgeAttr.size()
            // Tiny disc behind the badge so it pops against the
            // pet glyph.
            let bx = size.width - badgeSize.width - 4
            let by = size.height - badgeSize.height - 4
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: bx - 2, y: by - 2,
                width: badgeSize.width + 4, height: badgeSize.height + 4
            )).fill()
            badgeAttr.draw(at: NSPoint(x: bx, y: by))
        }

        return image
    }
}
