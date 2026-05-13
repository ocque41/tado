// Relay command palette — ⌘K modal overlay per brief section 8.
//
// In-window ZStack overlay (not a separate NSPanel) so backdrop
// blur applies to the host content. The palette modal slides up
// 12px while fading in over 220ms.
//
// Three rows: head (›  + 26pt input + ⌘K kbd), grouped list,
// foot (kbd hints + version).
//
// Keyboard navigation: ↑/↓ move selection, ↵ activate, Esc close.

import SwiftUI

/// Presentation state for the palette. A single
/// `@AppStorage`-style state owned by ContentView; the palette
/// toggles via `Binding<Bool>`.
@MainActor
struct RelayCommandPalette: View {
    @Binding var isPresented: Bool

    @Environment(AppState.self) private var appState
    @Environment(RelayThemeStore.self) private var themeStore
    @Environment(\.relayTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var inputFocused: Bool

    /// Opens Explore — phase 4 wires this to a real action.
    var onOpenExplore: () -> Void = {}

    private var registry: CommandRegistry {
        CommandRegistry(
            appState: appState,
            openWindow: openWindow,
            openPalette: { isPresented.toggle() },
            toggleTheme: { themeStore.toggle() },
            openExplore: { onOpenExplore() }
        )
    }

    private var items: [CommandItem] {
        let all = registry.items()
        if query.isEmpty { return all }
        let q = query.lowercased()
        return all.filter { $0.label.lowercased().contains(q) }
    }

    private var groups: [(RelayCommandGroup, [(Int, CommandItem)])] {
        // Items by group, preserving the registry's ordering.
        // Pair each item with its global index in `items` so
        // keyboard nav can address rows uniformly.
        let indexed = Array(items.enumerated())
        var dict: [RelayCommandGroup: [(Int, CommandItem)]] = [:]
        for (idx, item) in indexed {
            dict[item.group, default: []].append((idx, item))
        }
        return RelayCommandGroup.allCases.compactMap { g in
            guard let arr = dict[g], !arr.isEmpty else { return nil }
            return (g, arr)
        }
    }

    var body: some View {
        ZStack {
            // Scrim
            Color.black.opacity(theme == .ink ? 0.45 : 0.30)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
                .onTapGesture { dismiss() }

            // Modal card
            VStack(spacing: 0) {
                head
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)
                list
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)
                foot
            }
            .frame(maxWidth: 620)
            .frame(maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .fill(RelayPalette.background(for: theme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .shadow(
                color: RelayShadow.modalColor,
                radius: RelayShadow.modalRadius,
                x: RelayShadow.modalX,
                y: RelayShadow.modalY
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom)),
                removal: .opacity
            ))
        }
        .onAppear {
            inputFocused = true
            query = ""
            selectedIndex = 0
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            activate()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    // MARK: - Head

    private var head: some View {
        HStack(spacing: 14) {
            Text("›")
                .font(Typography.sans(size: 18, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            TextField("Search surfaces, actions, sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.sans(size: 26, weight: .light))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .focused($inputFocused)
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }
            RelayKbdPill(text: "⌘K")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.0) { group, indexedItems in
                        groupHeader(group: group, count: indexedItems.count)
                        ForEach(indexedItems, id: \.1.id) { idx, item in
                            row(globalIndex: idx, item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func groupHeader(group: RelayCommandGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(group.rawValue)
                .font(Typography.sans(size: 9, weight: .semibold))
                .tracking(RelayTracking.brand(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Text("· \(count)")
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func row(globalIndex: Int, item: CommandItem) -> some View {
        let active = globalIndex == selectedIndex
        return Button(action: { activate(item: item) }) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if active {
                    Rectangle()
                        .fill(RelayPalette.terracotta)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                }
                Text(item.hint ?? "›")
                    .font(Typography.sans(size: 10, weight: .medium))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(active
                        ? RelayPalette.terracotta
                        : RelayPalette.foreground3(for: theme))
                    .frame(width: 36, alignment: .leading)
                    .padding(.leading, active ? 18 : 20)
                Text(item.label)
                    .font(Typography.sans(size: 15, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let meta = item.meta {
                    Text(meta.uppercased())
                        .font(Typography.sans(size: 9, weight: .medium))
                        .tracking(RelayTracking.caps(9))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                        .padding(.trailing, 20)
                }
            }
            .frame(height: 36)
            .background(active ? RelayPalette.wash(for: theme) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = globalIndex }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NO MATCHES")
                .font(Typography.sans(size: 9, weight: .medium))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Text(query)
                .font(Typography.sans(size: 22, weight: .light))
                .foregroundStyle(RelayPalette.foreground(for: theme))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    // MARK: - Foot

    private var foot: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                kbdLabelGroup(["↑", "↓"], label: "navigate")
                kbdLabelGroup(["↵"], label: "select")
                kbdLabelGroup(["esc"], label: "close")
            }
            Spacer()
            Text("TADO · v1.3")
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RelayPalette.wash(for: theme))
    }

    private func kbdLabelGroup(_ keys: [String], label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                RelayKbdPill(text: k)
            }
            Text(label.uppercased())
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
    }

    // MARK: - Actions

    private func dismiss() {
        withAnimation(RelayAnim.overlay(reduce: reduce, dur: RelayMotionTokens.durPalette)) {
            isPresented = false
        }
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let n = items.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
    }

    private func activate() {
        guard !items.isEmpty,
              selectedIndex >= 0,
              selectedIndex < items.count
        else { return }
        activate(item: items[selectedIndex])
    }

    private func activate(item: CommandItem) {
        item.perform()
        dismiss()
    }
}
