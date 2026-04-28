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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(
                title: "Recipes",
                subtitle: "\(recipes.count) recipes · \(domeScope.label)",
                isLoading: isLoading
            ) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            if recipes.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    leftRail
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                    Divider().overlay(Palette.divider)
                    rightPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("No recipes seeded yet")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
            Text("Recipes are governed-answer templates the app and agents share. Click Seed defaults to install architecture-review, completion-claim, and team-handoff.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button(seedBusy ? "Seeding…" : "Seed defaults") {
                runSeedDefaults()
            }
            .buttonStyle(.borderedProminent)
            .disabled(seedBusy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recipes) { recipe in
                        recipeRow(recipe)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Palette.surface)
    }

    private func recipeRow(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        let isSelected = recipe.id == selectedID
        return Button(action: {
            selectedID = recipe.id
            // Reset stale answer when switching recipes so the right
            // pane never shows a citation set from a different intent.
            if lastAnswer?.intentKey != recipe.intentKey {
                lastAnswer = nil
                lastAnswerError = nil
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(recipe.title)
                        .font(Typography.title)
                        .foregroundStyle(isSelected ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if !recipe.enabled {
                        Text("Disabled")
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(recipe.intentKey)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                    scopeBadge(recipe.scope)
                    Spacer()
                }
                Text(recipe.description)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.surfaceAccentSoft : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func scopeBadge(_ scope: String) -> some View {
        Text(scope.capitalized)
            .font(Typography.micro)
            .foregroundStyle(scope == "project" ? Palette.warning : Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.surfaceAccentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
                        .font(Typography.body)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(20)
                }
            }
            .padding(20)
        }
    }

    private func rightHeader(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title)
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: 8) {
                Text(recipe.intentKey)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textSecondary)
                scopeBadge(recipe.scope)
                if let last = recipe.lastVerifiedAt {
                    Text("Last verified: \(last.prefix(10))")
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Text(recipe.description)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func policyCard(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Retrieval policy")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
            policyRow(label: "Knowledge scope", value: recipe.policy.knowledgeScope.capitalized)
            policyRow(label: "Topics", value: recipe.policy.topics.isEmpty ? "any" : recipe.policy.topics.joined(separator: ", "))
            policyRow(label: "Knowledge kinds", value: recipe.policy.knowledgeKinds.isEmpty ? "any" : recipe.policy.knowledgeKinds.joined(separator: ", "))
            policyRow(label: "Freshness decay", value: "\(recipe.policy.freshnessDecayDays) days")
            policyRow(label: "Max tokens", value: "\(recipe.policy.maxTokens)")
            policyRow(label: "Min combined score", value: String(format: "%.2f", recipe.policy.minCombinedScore))
            policyRow(label: "Top-K", value: "\(recipe.policy.topK)")
        }
        .padding(12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func policyRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
        }
    }

    private func runCard(_ recipe: DomeRpcClient.RetrievalRecipe) -> some View {
        HStack(spacing: 10) {
            Button(runningRecipe ? "Running…" : "Run recipe") {
                runRecipe(recipe)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runningRecipe || !recipe.enabled)

            if let path = templatePath(for: recipe), FileManager.default.fileExists(atPath: path) {
                Button("Edit template") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .buttonStyle(.borderless)
                .help("Open \(path) in the system editor")
            }

            if recipe.scope == "global" {
                Button(seedBusy ? "Resetting…" : "Reset to default") {
                    runSeedDefaults()
                }
                .buttonStyle(.borderless)
                .disabled(seedBusy)
                .help("Re-seed all baked default recipes — restores any deleted defaults and refreshes templates.")
            }
            Spacer()
        }
    }

    private func answerCard(_ answer: DomeRpcClient.GovernedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Governed answer")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button("Copy answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer.answer, forType: .string)
                }
                .buttonStyle(.borderless)
                Button("Copy as citation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(citationMarkdown(for: answer), forType: .string)
                }
                .buttonStyle(.borderless)
            }
            Text(answer.answer)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if !answer.citations.isEmpty {
                Text("Citations (\(answer.citations.count))")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                ForEach(answer.citations) { citation in
                    citationRow(citation)
                }
            }

            if !answer.missingAuthority.isEmpty {
                Text("Missing authority")
                    .font(Typography.title)
                    .foregroundStyle(Palette.warning)
                ForEach(answer.missingAuthority, id: \.self) { gap in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.warning)
                            .font(.system(size: 12))
                        Text(gap)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
    }

    private func citationRow(_ citation: DomeRpcClient.Citation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "quote.opening")
                .foregroundStyle(Palette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(citation.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(citation.topic)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                    scopeBadge(citation.scope)
                    Text(String(format: "conf %.2f · fresh %.2f", citation.confidence, citation.freshness))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Palette.danger)
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button("Dismiss") { lastAnswerError = nil }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        Task.detached {
            let count = DomeRpcClient.recipeSeedDefaults()
            await MainActor.run {
                seedBusy = false
                if count != nil {
                    Task { await reload() }
                }
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
