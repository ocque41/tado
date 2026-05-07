import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Root view of the Pets *settings* window — the AppExtension
/// entry-point reachable from the Extensions page or by posting
/// `.openExtensionWindowRequest` with id `pets`.
///
/// Sections
/// - **Enable / disable** the floating panel.
/// - **Pet picker** — grid of the 8 built-in pets, plus a
///   "Custom" tab listing every sprite under
///   `<storage-root>/pets/custom/` (both flat-file pets like
///   `<id>.png` and folder pets like `<id>/frame-001.png`).
/// - **Position** — corner picker + opacity slider.
/// - **Thought-bubble** toggle.
/// - **Upload image sequence…** button — pick one or many images,
///   give the pet a name, save as a folder of frames the cache
///   plays as an animated loop.
/// - **Hatch new pet…** button → opens `PetsHatchSheet`.
struct PetsWindowRoot: View {
    @State private var settings: PetsPreferences = {
        PetsPreferencesStore.shared.loadIfNeeded()
        return PetsPreferencesStore.shared.current
    }()
    @State private var customPets: [CustomPet] = []
    @State private var hatchRequest: PetsHatchRequest?
    @State private var uploadDraft: UploadDraft?
    @State private var lastUploadError: String?
    @State private var lastGifCrafterMessage: String?
    /// Per-state staging buffer for the "Build per-state pet"
    /// section. One entry per `PetState` raw value; the URLs
    /// keep the user's pick order (which becomes frame order).
    @State private var perStateFrames: [String: [URL]] = [:]
    @State private var perStateName: String = ""
    @State private var perStateFrameDuration: Double = 0.12
    @State private var lastPerStateError: String?
    @State private var lastPerStateMessage: String?

    /// Snapshot of an entry under `<storage-root>/pets/custom/`.
    /// Carries everything the picker grid needs without re-walking
    /// the disk on every redraw.
    struct CustomPet: Identifiable, Equatable {
        let id: String          // "custom:<stem>"
        let displayName: String
        let previewURL: URL?
        let frameCount: Int
        let storageURL: URL     // file or folder we'd remove on delete
    }

    /// In-flight upload that needs the user to confirm a name +
    /// frame duration before it lands. Held while the naming
    /// sheet is on screen.
    struct UploadDraft: Identifiable, Equatable {
        let id = UUID()
        var sourceURLs: [URL]
        var name: String
        var frameDurationSeconds: Double
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Toggle(isOn: Binding(
                    get: { settings.enabled },
                    set: { newValue in mutate { $0.enabled = newValue } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Pets")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show the floating companion above all apps.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                builtInsSection
                customSection
                uploadSection
                perStateBuilderSection
                gifCrafterSection
                positionSection
                bubbleSection
                liveAgentSection
                hatchSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            PetsPreferencesStore.shared.loadIfNeeded()
            settings = PetsPreferencesStore.shared.current
            refreshCustomList()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // Cheap poll so external mutations (slash command,
            // popover, direct settings.json edit) reflect in
            // the picker.
            let fresh = PetsPreferencesStore.shared.current
            if fresh != settings { settings = fresh }
        }
        .sheet(item: $hatchRequest) { req in
            PetsHatchSheet(
                request: req,
                onCompleted: { _ in refreshCustomList() },
                onDismiss: { hatchRequest = nil }
            )
        }
        .sheet(item: $uploadDraft) { _ in
            uploadNamingSheet
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pets")
                .font(.system(size: 18, weight: .bold))
            Text("Floating companion that mirrors what Tado is doing across every project, run, and perf cycle.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var builtInsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in pets")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(PetID.builtIn, id: \.self) { petID in
                    petCard(petID: petID, label: petID.capitalized, isCustom: false, frameCount: nil, deleteAction: nil)
                }
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        if !customPets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom pets")
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(customPets) { pet in
                        petCard(
                            petID: pet.id,
                            label: pet.displayName,
                            isCustom: true,
                            frameCount: pet.frameCount,
                            deleteAction: { delete(customPet: pet) }
                        )
                    }
                }
            }
        }
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upload your own pet")
                .font(.system(size: 13, weight: .semibold))
            Text("Pick one image for a static pet, or several to create an animation. PNG, JPEG, APNG, GIF, WebP, TIFF, HEIC. Selection order becomes frame order.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    pickImageSequence()
                } label: {
                    Label("Upload image sequence…", systemImage: "photo.stack")
                }

                if let lastUploadError {
                    Text(lastUploadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Build per-state pet" section. Lets the user stage a
    /// distinct image sequence for *each* PetState (idle /
    /// running / awaitingResponse / etc), then save the lot as
    /// one v2 custom pet whose floating-panel sprite swaps
    /// animations as the aggregate state changes. Missing
    /// states fall back to the picker's first usable sprite at
    /// playback time, so a partial set still renders.
    ///
    /// All staging is in-memory (just URLs); files are only
    /// copied into `<storage-root>/pets/custom/<id>/states/...`
    /// when the user clicks "Save pet".
    private var perStateBuilderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Build per-state pet")
                .font(.system(size: 13, weight: .semibold))
            Text("Add an animation sequence per state. Each row is one PetState — pick one or many images; their order becomes frame order. Leave a state empty to fall back to the pet's first available sprite at runtime. When you're happy, give the pet a name and click Save pet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Pet name")
                    .font(.system(size: 11))
                TextField("e.g. Stealth Coder", text: $perStateName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Text("Frame")
                    .font(.system(size: 11))
                Stepper(
                    value: $perStateFrameDuration,
                    in: 0.04...1.0,
                    step: 0.02
                ) {
                    Text(String(format: "%.0f ms", perStateFrameDuration * 1000))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }

            VStack(spacing: 6) {
                ForEach(PetState.allCases, id: \.rawValue) { state in
                    perStateRow(state)
                }
            }

            HStack(spacing: 8) {
                Button {
                    saveStagedPerStatePet()
                } label: {
                    Label("Save pet", systemImage: "tray.and.arrow.down.fill")
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button {
                    perStateFrames = [:]
                    perStateName = ""
                    lastPerStateError = nil
                    lastPerStateMessage = nil
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .disabled(perStateStagedTotal == 0 && perStateName.isEmpty)

                Spacer()

                if let msg = lastPerStateMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.green.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = lastPerStateError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One row of the per-state builder. Header (state name +
    /// frame count + Add/Clear buttons) on top, frame chips
    /// underneath when the user has staged anything for this
    /// state. Each chip shows a thumbnail preview + filename +
    /// a remove button.
    @ViewBuilder
    private func perStateRow(_ state: PetState) -> some View {
        let frames = perStateFrames[state.rawValue] ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(state.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 132, alignment: .leading)
                Text(frames.isEmpty ? "no frames" : "\(frames.count) frame\(frames.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(frames.isEmpty ? .secondary : .primary)
                Spacer()
                Button {
                    pickFramesForState(state)
                } label: {
                    Label("Add frames…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !frames.isEmpty {
                    Button {
                        perStateFrames[state.rawValue] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear frames for \(state.displayLabel)")
                }
            }

            if !frames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { idx, url in
                            perStateFrameChip(state: state, index: idx, url: url)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Thumbnail chip for one staged frame. Shows the file's
    /// preview + filename + a remove (×) button.
    @ViewBuilder
    private func perStateFrameChip(state: PetState, index: Int, url: URL) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        )
                }
                Button {
                    var arr = perStateFrames[state.rawValue] ?? []
                    if index < arr.count {
                        arr.remove(at: index)
                        if arr.isEmpty {
                            perStateFrames[state.rawValue] = nil
                        } else {
                            perStateFrames[state.rawValue] = arr
                        }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .offset(x: 4, y: -4)
                .help("Remove frame")
            }
            Text("\(index + 1)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var perStateStagedTotal: Int {
        perStateFrames.values.reduce(0) { $0 + $1.count }
    }

    /// Open NSOpenPanel multi-select scoped to image files. The
    /// user's selection order becomes the frame order.
    @MainActor
    private func pickFramesForState(_ state: PetState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .png, .jpeg, .gif, .webP, .tiff, .bmp, .heic, .image
        ]
        panel.message = "Pick one or many images for \(state.displayLabel). Selection order becomes frame order."
        panel.prompt = "Add to \(state.displayLabel)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var existing = perStateFrames[state.rawValue] ?? []
        existing.append(contentsOf: panel.urls)
        perStateFrames[state.rawValue] = existing
        lastPerStateError = nil
        lastPerStateMessage = nil
    }

    /// Run the staged sequences through `PetsHatchService`, then
    /// reset the form on success and refresh the picker grid so
    /// the new pet shows up immediately.
    @MainActor
    private func saveStagedPerStatePet() {
        let trimmed = perStateName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lastPerStateError = "Give the pet a name first."
            lastPerStateMessage = nil
            return
        }
        if perStateStagedTotal == 0 {
            lastPerStateError = "Add at least one frame to one state."
            lastPerStateMessage = nil
            return
        }

        // Convert the [String: [URL]] buffer into [PetState: [URL]]
        // so the service signature stays type-safe.
        var typed: [PetState: [URL]] = [:]
        for state in PetState.allCases {
            if let urls = perStateFrames[state.rawValue], !urls.isEmpty {
                typed[state] = urls
            }
        }

        do {
            let petID = try PetsHatchService.shared.importPerStateSequence(
                name: trimmed,
                sequences: typed,
                frameDurationSeconds: perStateFrameDuration
            )
            // Set as active so the floating panel switches to it
            // on the next aggregate recompute.
            mutate { $0.pet = petID }
            lastPerStateMessage = "Saved \(trimmed) (\(typed.count) state\(typed.count == 1 ? "" : "s"), \(perStateStagedTotal) frames). Now active."
            lastPerStateError = nil
            perStateFrames = [:]
            perStateName = ""
            refreshCustomList()
        } catch {
            lastPerStateError = "Save failed: \(error.localizedDescription)"
            lastPerStateMessage = nil
        }
    }

    /// "Craft GIF…" section. Picks a folder of stills, then
    /// spawns the `tado-gif-crafter` agent in a Tado terminal
    /// tile via `tado-deploy`. The agent reads `$GIF_INPUT` /
    /// `$GIF_OUTPUT` from its env, runs the `tado-gif-craft`
    /// skill (max-bounds align + run-rapid-and-stop cadence),
    /// and emits a `tado_notify` when the GIF lands.
    private var gifCrafterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Craft GIF from stills")
                .font(.system(size: 13, weight: .semibold))
            Text("Pick a folder of frames. A Tado agent terminal aligns them on a common canvas, runs through them rapidly, and holds the last frame for a beat before looping. Output: an animated GIF you can use as a custom-pet sprite or anywhere else.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    spawnGifCrafter()
                } label: {
                    Label("Craft GIF…", systemImage: "wand.and.stars")
                }
                if let msg = lastGifCrafterMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(msg.hasPrefix("Failed") ? .red : .green.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func spawnGifCrafter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Frames"
        panel.message = "Pick a folder of stills (PNG / JPEG / WebP / TIFF / GIF). Filename order becomes playback order."
        let response = panel.runModal()
        guard response == .OK, let inputURL = panel.urls.first else { return }

        // Default output: <storage-root>/pets/gifs/<basename>-<uuid>.gif.
        // Lives next to custom pets so the result is easy to drop
        // into a per-state mapping later.
        let basename = inputURL.lastPathComponent.isEmpty ? "stills" : inputURL.lastPathComponent
        let safeBasename = basename
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let gifsDir = PetsHatchService.shared.customPetsDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("gifs", isDirectory: true)
        try? FileManager.default.createDirectory(at: gifsDir, withIntermediateDirectories: true)
        let outputURL = gifsDir.appendingPathComponent(
            "\(safeBasename.isEmpty ? "stills" : safeBasename)-\(UUID().uuidString.prefix(8)).gif"
        )

        // Build the prompt for the tado-gif-crafter agent. The
        // env values are baked into the prompt body since
        // `tado-deploy` doesn't expose a custom-env flag — the
        // agent reads them by parsing the prompt itself.
        let prompt = """
        You are the tado-gif-crafter agent. Run the tado-gif-craft skill.

        Inputs (export these as env before running the skill):
          GIF_INPUT="\(inputURL.path)"
          GIF_OUTPUT="\(outputURL.path)"
          GIF_FPS=12
          GIF_HOLD_MS=700
          GIF_ANCHOR=bottom-center
          GIF_SCALE=pad-to-max
          GIF_LOOP=0

        Then follow the skill end-to-end:
        1. Resolve the input file list.
        2. Probe each frame's dimensions to find the common canvas.
        3. Stage padded frames in a mktemp dir with a trap cleanup.
        4. Render the GIF with action-FPS delay, hold the last frame.
        5. Validate frame count + delay sequence.
        6. Emit tado_notify and exit.

        End-of-turn: print one line summarising frames / FPS / hold,
        then exit. No follow-up turns.
        """

        // Launch via `tado-deploy`. Works whether the user has
        // the CLI on PATH (`~/.local/bin/tado-deploy`) or via
        // the bundled `.app` exec. We try the home path first.
        let deployPath = NSHomeDirectory() + "/.local/bin/tado-deploy"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: deployPath)
        task.arguments = [
            prompt,
            "--agent", "tado-gif-crafter",
            "--engine", "claude"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            lastGifCrafterMessage = "Spawned GIF crafter — output will land at \(outputURL.lastPathComponent)"
        } catch {
            lastGifCrafterMessage = "Failed to spawn tado-deploy: \(error.localizedDescription). Run from terminal: tado-deploy '\(prompt.replacingOccurrences(of: "\n", with: " "))' --agent tado-gif-crafter"
        }
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position")
                .font(.system(size: 13, weight: .semibold))
            Picker("Corner", selection: Binding(
                get: { settings.corner },
                set: { newValue in mutate { $0.corner = newValue; $0.positionX = 0; $0.positionY = 0 } }
            )) {
                Text("Top right").tag("topRight")
                Text("Top left").tag("topLeft")
                Text("Bottom right").tag("bottomRight")
                Text("Bottom left").tag("bottomLeft")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Opacity")
                    .font(.system(size: 11))
                Slider(value: Binding(
                    get: { settings.opacity },
                    set: { newValue in mutate { $0.opacity = newValue } }
                ), in: 0.4...1.0, step: 0.05)
                Text(String(format: "%.0f%%", settings.opacity * 100))
                    .font(.system(size: 11))
                    .frame(width: 40, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    private var bubbleSection: some View {
        Toggle(isOn: Binding(
            get: { settings.showThoughtBubble },
            set: { newValue in mutate { $0.showThoughtBubble = newValue } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show thought-bubble")
                    .font(.system(size: 13, weight: .medium))
                Text("Caption above the pet describing the highest-priority active surface.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    /// Live-agent companion. When toggled on, the Pets
    /// coordinator boots a long-running `tado-pet-companion`
    /// tile on the canvas; the floating panel's double-click
    /// gesture sends free-form prompts into that tile.
    private var liveAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.liveAgent },
                set: { newValue in mutate { $0.liveAgent = newValue } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live agent companion")
                        .font(.system(size: 13, weight: .medium))
                    Text("Spawn a long-running Tado agent tile that polls every active session every 60 seconds. Double-click the floating pet to send the agent a prompt — it can intervene on running sessions, send messages on your behalf, or summarise what every tile is doing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if settings.liveAgent {
                if let sessionID = settings.liveAgentSessionID {
                    Text("Companion session: \(sessionID.prefix(8))…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospaced()
                } else {
                    // The companion does not auto-spawn at app
                    // launch even when this preference is on (the
                    // launch path can't safely shell `tado-deploy`
                    // before the IPC broker is wired). Surface an
                    // explicit "Start now" affordance so the
                    // toggle's on-state is honest.
                    HStack(spacing: 8) {
                        Text("Companion is enabled but not currently running.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Start companion now") {
                            PetsCoordinator.shared.spawnLiveCompanionIfNeeded()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var hatchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hatch a new pet")
                .font(.system(size: 13, weight: .semibold))
            Text("Describe a pet and Tado will generate one. v1 ships a placeholder; real generation lights up in v1.1.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                hatchRequest = PetsHatchRequest(id: UUID(), prompt: "")
            } label: {
                Label("Hatch new pet…", systemImage: "sparkles")
            }
        }
    }

    // MARK: - Upload pipeline

    @MainActor
    private func pickImageSequence() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Use as Pet"
        panel.message = "Pick one image for a static pet, or several for an animation. Order matters — selection order becomes frame order."
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                .png, .jpeg, .gif, .tiff, .bmp,
                UTType(filenameExtension: "apng") ?? .png,
                UTType(filenameExtension: "webp") ?? .png,
                UTType(filenameExtension: "heic") ?? .png
            ]
        }

        let response = panel.runModal()
        guard response == .OK, !panel.urls.isEmpty else { return }

        let suggestedName = panel.urls.first?.deletingPathExtension().lastPathComponent ?? "custom"
        uploadDraft = UploadDraft(
            sourceURLs: panel.urls,
            name: suggestedName,
            frameDurationSeconds: 0.12
        )
    }

    private var uploadNamingSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save custom pet")
                .font(.system(size: 14, weight: .semibold))

            if let draft = uploadDraft {
                if draft.sourceURLs.count > 1 {
                    Text("\(draft.sourceURLs.count) frames will play in selection order at the duration below. Lower number = faster animation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This pet will use one static frame.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 11))
                TextField("e.g. starfish, pixel-goblin", text: Binding(
                    get: { uploadDraft?.name ?? "" },
                    set: { newValue in uploadDraft?.name = newValue }
                ))
                .textFieldStyle(.roundedBorder)
            }

            if (uploadDraft?.sourceURLs.count ?? 0) > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Frame duration: %.2fs", uploadDraft?.frameDurationSeconds ?? 0.12))
                        .font(.system(size: 11))
                    Slider(value: Binding(
                        get: { uploadDraft?.frameDurationSeconds ?? 0.12 },
                        set: { newValue in uploadDraft?.frameDurationSeconds = newValue }
                    ), in: 0.05...0.5, step: 0.01)
                }
            }

            HStack {
                Button("Cancel") {
                    uploadDraft = nil
                    lastUploadError = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    commitUpload()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((uploadDraft?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @MainActor
    private func commitUpload() {
        guard let draft = uploadDraft else { return }
        do {
            let petID = try PetsHatchService.shared.importImageSequence(
                from: draft.sourceURLs,
                name: draft.name,
                frameDurationSeconds: draft.frameDurationSeconds
            )
            // Activate the new pet right away so the user sees the
            // result on the floating panel without an extra click.
            mutate { $0.pet = petID }
            uploadDraft = nil
            lastUploadError = nil
            refreshCustomList()
            // Force a fresh decode in case the user re-uploaded
            // under a colliding name (the importer renames, but
            // the cache might still hold a previous rendering).
            PetSpriteCache.shared.evict(petID: petID)
            PetSpriteCache.shared.preheat(petID: petID)
        } catch {
            lastUploadError = error.localizedDescription
        }
    }

    @MainActor
    private func delete(customPet: CustomPet) {
        try? FileManager.default.removeItem(at: customPet.storageURL)
        // If the deleted pet was the active one, fall back to
        // the default built-in.
        if settings.pet == customPet.id {
            mutate { $0.pet = PetID.default }
        }
        PetSpriteCache.shared.evict(petID: customPet.id)
        refreshCustomList()
    }

    // MARK: - Helpers

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    }

    @ViewBuilder
    private func petCard(
        petID: String,
        label: String,
        isCustom: Bool,
        frameCount: Int?,
        deleteAction: (() -> Void)?
    ) -> some View {
        let selected = settings.pet == petID
        Button {
            mutate { $0.pet = petID }
        } label: {
            VStack(spacing: 4) {
                let frames = PetSpriteCache.shared.frames(petID: petID, state: .idle)
                if let frame = frames.first {
                    Image(nsImage: frame.image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 48, height: 48)
                } else {
                    Color.gray.opacity(0.3).frame(width: 48, height: 48)
                }
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let frameCount, frameCount > 1 {
                    Text("\(frameCount) frames")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let deleteAction {
                Button("Delete", role: .destructive) { deleteAction() }
            }
        }
    }

    /// Walk `<storage-root>/pets/custom/` and turn every entry
    /// into a `CustomPet` row for the picker. Three layouts are
    /// recognised, so a pet saved by *any* of the three flows
    /// (flat upload, single-state folder, v2 per-state) shows up
    /// in the same inventory:
    ///
    /// 1. **Flat file**  — `<id>.png` (or `.apng` / `.gif` / …).
    ///    One sprite, plays in every state.
    /// 2. **v1 folder**  — `<id>/frame-001.<ext>` … directly
    ///    inside the pet dir, with optional `meta.json` carrying
    ///    name + per-frame duration. One animation, plays in
    ///    every state.
    /// 3. **v2 per-state folder**  — `<id>/states/<state>/frame-NNN.<ext>`
    ///    plus `meta.json` (`version: 2`) with a `states` map.
    ///    Distinct animation per state. The preview thumbnail
    ///    comes from the highest-priority state available
    ///    (idle first, then any other), so the picker chip
    ///    shows the calmest pose.
    ///
    /// All three feed `CustomPet.storageURL = <pet-dir|file>` so
    /// the delete affordance can rip out the right thing.
    private func refreshCustomList() {
        let dir = PetsHatchService.shared.customPetsDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            customPets = []
            return
        }

        var pets: [CustomPet] = []
        let imageExts: Set<String> = ["png", "apng", "gif", "jpeg", "jpg", "webp", "tiff", "bmp", "heic"]
        let frameImageExts: Set<String> = ["png", "jpeg", "jpg", "webp", "tiff", "bmp", "heic", "apng", "gif"]

        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                guard let pet = customPetFromDirectory(url, frameImageExts: frameImageExts) else {
                    continue
                }
                pets.append(pet)
            } else if imageExts.contains(url.pathExtension.lowercased()) {
                // Flat-file pet (legacy layout 1).
                let stem = url.deletingPathExtension().lastPathComponent
                pets.append(CustomPet(
                    id: "custom:\(stem)",
                    displayName: String(stem.prefix(16)),
                    previewURL: url,
                    frameCount: 1,
                    storageURL: url
                ))
            }
        }

        customPets = pets
    }

    /// Resolve a single folder pet (v1 or v2) into a CustomPet
    /// row. Returns nil for folders that hold no usable frames
    /// (the legacy bug here was: the v1 path returned nil for
    /// every v2 pet because frames live two levels deep).
    private func customPetFromDirectory(_ url: URL, frameImageExts: Set<String>) -> CustomPet? {
        // Try meta.json first — gives us the name and tells us
        // if this is a v2 layout.
        let metaURL = url.appendingPathComponent("meta.json")
        let meta: [String: Any]? = (try? Data(contentsOf: metaURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        let storedName = (meta?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let displayName = storedName ?? url.lastPathComponent
        let version = (meta?["version"] as? Int) ?? 1

        if version >= 2, let statesMap = meta?["states"] as? [String: String], !statesMap.isEmpty {
            // v2: the picker preview should come from a real
            // state animation. Prefer the one with the highest
            // priority that has frames; otherwise fall back to
            // the first state in the map.
            let priorityOrder: [String] = [
                "idle", "running", "needsInput", "awaitingResponse",
                "eternalRunning", "perfRegressed", "done"
            ]
            let preferredKeys = priorityOrder.filter { statesMap[$0] != nil }
                + statesMap.keys.filter { !priorityOrder.contains($0) }

            var previewURL: URL?
            var totalFrames = 0
            for key in preferredKeys {
                guard let rel = statesMap[key] else { continue }
                let target = url.appendingPathComponent(rel)
                let frames = framesUnder(target, exts: frameImageExts)
                totalFrames += frames.count
                if previewURL == nil, let first = frames.first {
                    previewURL = first
                }
            }
            // A v2 pet that lists states but every state file is
            // missing is still listed — the user staged the
            // structure even if individual frames disappeared.
            // The preview falls back to nil so the picker shows
            // the placeholder gradient.
            return CustomPet(
                id: "custom:\(url.lastPathComponent)",
                displayName: String(displayName.prefix(16)),
                previewURL: previewURL,
                frameCount: max(totalFrames, statesMap.count),
                storageURL: url
            )
        }

        // v1 folder — frames live at the top of the pet dir.
        let frames = framesUnder(url, exts: frameImageExts)
        guard !frames.isEmpty else { return nil }
        return CustomPet(
            id: "custom:\(url.lastPathComponent)",
            displayName: String(displayName.prefix(16)),
            previewURL: frames.first,
            frameCount: frames.count,
            storageURL: url
        )
    }

    /// Walk `target` (file or directory) and return the sorted
    /// list of frame URLs. If `target` is a single file, returns
    /// `[target]`. If it's a directory, returns image children
    /// sorted by `localizedStandardCompare`.
    private func framesUnder(_ target: URL, exts: Set<String>) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            return []
        }
        if !isDir.boolValue {
            return exts.contains(target.pathExtension.lowercased()) ? [target] : []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func mutate(_ change: (inout PetsPreferences) -> Void) {
        var next = settings
        change(&next)
        PetsPreferencesStore.shared.update { $0 = next }
        settings = next
    }
}
