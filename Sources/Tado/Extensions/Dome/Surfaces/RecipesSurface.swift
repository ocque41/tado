import AppKit
import Foundation
import SwiftUI

/// v0.11 — browse + run retrieval recipes (Tado's "verified queries").
///
/// Recipes are intent-keyed retrieval policies that Tado renders into
/// a deterministic markdown answer with citations. Three baked
/// defaults ship with the app: `architecture-review`,
/// `completion-claim`, `team-handoff`. Project-scoped overrides can
/// live at `<project>/.tado/verified-prompts/<intent>.md`.
///
/// Layout:
///   - Left rail: list of recipes in the active scope.
///   - Right pane: when one is selected, shows the policy summary
///     plus a "Run" button → renders the `GovernedAnswer` with
///     citations + missing-authority callouts.
struct RecipesSurface: View {
    let domeScope: DomeScopeSelection

    @State private var recipes: [DomeRpcClient.RetrievalRecipe] = []
    @State private var selectedID: String?
    @State private var runningRecipe = false
    @State private var lastAnswer: DomeRpcClient.GovernedAnswer?
    @State private var lastAnswerError: String?
    @State private var isLoading = false
    @State private var seedBusy = false
    /// v0.17 — inline status banner shown after a Seed/Reset click
    /// so the button has visible success/failure feedback. Without
    /// this the operator clicked the button, the FFI returned, and
    /// nothing on screen changed (the recipes were already seeded
    /// at app launch from `DomeExtension.onAppLaunch`, so the list
    /// was identical post-call). The user reported this as "I am
    /// clicking seed defaults and nothing is happening" — this
    /// state is the fix.
    @State private var seedFeedback: SeedFeedback?

    private enum SeedFeedback: Equatable {
        case ok(count: Int)
        case error(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(
                title: "Recipes",
                subtitle: "\(recipes.count) recipes · \(domeScope.label)",
                isLoading: isLoading
            ) {
                Task { await reload() }
            }
            if recipes.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    leftRail
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                    Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
                    rightPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reload() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.ink4)
                Text("No recipes seeded yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Recipes are governed-answer templates the app and agents share. Click Seed defaults to install architecture-review, completion-claim, and team-handoff.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            OutlineButton(
                seedBusy ? "Seeding…" : "Seed defaults",
                icon: "sparkles",
                size: .regular,
                variant: .accent,
                action: { runSeedDefaults() }
            )
            .disabled(seedBusy)
            seedFeedbackBanner
            Text("RETRIEVAL RECIPES  ·  intent-keyed policy + template  ·  three baked defaults: architecture-review, completion-claim, team-handoff")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// v0.17 — inline confirmation row for the Seed/Reset action.
    /// Shown both in the empty state (right under the prominent
    /// button) and in the right-pane "Reset to default" position so
    /// the operator can tell the click did something even when the
    /// recipe list was already populated. Auto-dismisses after a few
    /// seconds via the `task` attached to it.
    @ViewBuilder
    private var seedFeedbackBanner: some View {
        if let feedback = seedFeedback {
            HStack(spacing: 8) {
                switch feedback {
                case .ok(let count):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.green)
                    Text("Seeded \(count) default recipe\(count == 1 ? "" : "s") at global scope.")
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                case .error(let message):
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Palette.danger)
                    Text(message)
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            .task(id: feedback) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if seedFeedback == feedback { seedFeedback = nil }
            }
        }
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OverlineLabel("Recipes")
                Spacer()
                Text("\(recipes.count) total")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recipes) { recipe in
                        recipeRow(recipe)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
            }
        }
        .background(Palette.bgElev)
    }

    private func recipeRow(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        let isSelected = recipe.id == selectedID
        return Button(action: {
            selectedID = recipe.id
            if lastAnswer?.intentKey != recipe.intentKey {
                lastAnswer = nil
                lastAnswerError = nil
            }
        }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(recipe.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                    Spacer()
                    if !recipe.enabled {
                        StatusPill("disabled", variant: .draft)
                    }
                }
                HStack(spacing: 6) {
                    Text(recipe.intentKey)
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                    scopeBadge(recipe.scope)
                    Spacer()
                }
                Text(recipe.description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.bgRowHi : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Palette.accent).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scopeBadge(_ scope: String) -> some View {
        StatusPill(
            scope.lowercased(),
            variant: scope == "project" ? .review : .draft
        )
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let recipe = selected {
                    rightHeader(recipe)
                    policyCard(recipe)
                    runCard(recipe)
                    if let answer = lastAnswer {
                        answerCard(answer)
                    }
                    if let err = lastAnswerError {
                        errorBanner(err)
                    }
                    Spacer(minLength: 12)
                } else {
                    Text("Pick a recipe on the left to see its policy and run it.")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Palette.ink3)
                        .padding(20)
                }
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 20)
        }
    }

    private func rightHeader(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(recipe.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Palette.ink)
                Spacer()
                scopeBadge(recipe.scope)
            }
            HStack(spacing: 8) {
                Text(recipe.intentKey)
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                if let last = recipe.lastVerifiedAt {
                    Text("·  Last verified \(last.prefix(10))")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
            }
            Text(recipe.description)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func policyCard(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OverlineLabel("Retrieval policy")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.bgPage)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }
            VStack(alignment: .leading, spacing: 0) {
                policyRow(label: "Knowledge scope", value: recipe.policy.knowledgeScope.capitalized)
                policyRow(label: "Topics", value: recipe.policy.topics.isEmpty ? "any" : recipe.policy.topics.joined(separator: ", "))
                policyRow(label: "Knowledge kinds", value: recipe.policy.knowledgeKinds.isEmpty ? "any" : recipe.policy.knowledgeKinds.joined(separator: ", "))
                policyRow(label: "Freshness decay", value: "\(recipe.policy.freshnessDecayDays) days")
                policyRow(label: "Max tokens", value: "\(recipe.policy.maxTokens)")
                policyRow(label: "Min combined score", value: String(format: "%.2f", recipe.policy.minCombinedScore))
                policyRow(label: "Top-K", value: "\(recipe.policy.topK)", trailing: true)
            }
        }
        .background(Palette.bgElev)
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
    }

    private func policyRow(label: String, value: String, trailing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 170, alignment: .leading)
                Text(value)
                    .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if !trailing {
                Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
            }
        }
    }

    private func runCard(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OutlineButton(
                    runningRecipe ? "Running…" : "Run recipe",
                    icon: "play.fill",
                    size: .regular,
                    variant: .accent,
                    action: { runRecipe(recipe) }
                )
                .disabled(runningRecipe || !recipe.enabled)

                if let path = templatePath(for: recipe), FileManager.default.fileExists(atPath: path) {
                    OutlineButton(
                        "Edit template",
                        icon: "square.and.pencil",
                        size: .regular,
                        variant: .standard,
                        action: { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    )
                    .help("Open \(path) in the system editor")
                }

                if recipe.scope == "global" {
                    OutlineButton(
                        seedBusy ? "Resetting…" : "Reset to default",
                        icon: "arrow.counterclockwise",
                        size: .regular,
                        variant: .ghost,
                        action: { runSeedDefaults() }
                    )
                    .disabled(seedBusy)
                    .help("Re-seed all baked default recipes — restores any deleted defaults and refreshes templates.")
                }
                Spacer()
            }
            seedFeedbackBanner
        }
    }

    private func answerCard(_ answer: DomeRpcClient.GovernedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                OverlineLabel("Governed answer")
                Spacer()
                OutlineButton(
                    "Copy answer",
                    icon: "doc.on.doc",
                    size: .small,
                    variant: .ghost,
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.answer, forType: .string)
                    }
                )
                OutlineButton(
                    "Copy as citation",
                    icon: "quote.opening",
                    size: .small,
                    variant: .ghost,
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(citationMarkdown(for: answer), forType: .string)
                    }
                )
            }
            Text(answer.answer)
                .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Palette.bgElev)
                .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))

            if !answer.citations.isEmpty {
                OverlineLabel("Citations · \(answer.citations.count)")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(answer.citations) { citation in
                        citationRow(citation)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
                .background(Palette.bgElev)
                .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
            }

            if !answer.missingAuthority.isEmpty {
                OverlineLabel("Missing authority", tint: Palette.warning)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(answer.missingAuthority, id: \.self) { gap in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Palette.warning)
                                .font(.system(size: 11))
                            Text(gap)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Palette.ink2)
                        }
                    }
                }
                .padding(12)
                .background(Palette.warning.opacity(0.06))
                .overlay(Rectangle().stroke(Palette.warning.opacity(0.3), lineWidth: DK.ruleW))
            }
        }
    }

    private func citationRow(_ citation: DomeRpcClient.Citation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "quote.opening")
                .foregroundStyle(Palette.ink4)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(citation.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(citation.topic)
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                    scopeBadge(citation.scope)
                    Text(String(format: "conf %.2f · fresh %.2f", citation.confidence, citation.freshness))
                        .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Palette.danger)
                .font(.system(size: 12))
            Text(message)
                .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
            Spacer()
            OutlineButton("Dismiss", size: .small, variant: .ghost) {
                lastAnswerError = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.danger.opacity(0.08))
        .overlay(Rectangle().stroke(Palette.danger.opacity(0.4), lineWidth: DK.ruleW))
    }

    // MARK: - Actions

    private var selected: DomeRpcClient.RetrievalRecipe? {
        guard let id = selectedID else { return nil }
        return recipes.first(where: { $0.id == id })
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let scope = domeScope.readKnowledgeScope == "merged" ? nil : domeScope.readKnowledgeScope
        let projectID = domeScope.projectIDString
        let fetched = await Task.detached { () -> [DomeRpcClient.RetrievalRecipe] in
            DomeRpcClient.recipeList(scope: scope, projectID: projectID)
        }.value
        recipes = fetched
        // Auto-select the first recipe so the right pane is never blank
        // on a freshly-loaded surface.
        if selectedID == nil || !fetched.contains(where: { $0.id == selectedID }) {
            selectedID = fetched.first?.id
        }
    }

    private func runRecipe(_ recipe: DomeRpcClient.RetrievalRecipe) {
        runningRecipe = true
        lastAnswerError = nil
        let intentKey = recipe.intentKey
        let projectID = domeScope.projectIDString
        Task.detached {
            let result = DomeRpcClient.recipeApply(intentKey: intentKey, projectID: projectID)
            await MainActor.run {
                runningRecipe = false
                if let result {
                    lastAnswer = result
                } else {
                    lastAnswerError = "Recipe didn't return an answer. The vault may be empty for this intent — write some notes first, or check the Audit log for the failure detail."
                }
            }
        }
    }

    private func runSeedDefaults() {
        seedBusy = true
        seedFeedback = nil
        Task { @MainActor in
            let count = await Task.detached {
                DomeRpcClient.recipeSeedDefaults()
            }.value
            seedBusy = false
            if let count {
                seedFeedback = .ok(count: count)
                await reload()
            } else {
                seedFeedback = .error(
                    message: "Couldn't seed defaults. The Dome daemon may still be booting — open Dome → Knowledge → System and check Vault status."
                )
            }
        }
    }

    /// Resolve `template_path` against the current project root if any,
    /// otherwise return nil (we can't open the global baked-in
    /// templates because they live in the .app bundle).
    private func templatePath(for recipe: DomeRpcClient.RetrievalRecipe) -> String? {
        guard let root = domeScope.projectRoot else { return nil }
        return (root as NSString).appendingPathComponent(recipe.templatePath)
    }

    private func citationMarkdown(for answer: DomeRpcClient.GovernedAnswer) -> String {
        var lines: [String] = []
        lines.append("> Governed answer for `\(answer.intentKey)`")
        lines.append("")
        lines.append(answer.answer)
        if !answer.citations.isEmpty {
            lines.append("")
            lines.append("Citations:")
            for c in answer.citations {
                lines.append("- \(c.title) (\(c.topic), \(c.scope)) — conf \(String(format: "%.2f", c.confidence))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
