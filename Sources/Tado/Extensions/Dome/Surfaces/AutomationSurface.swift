import AppKit
import Foundation
import SwiftUI

/// v0.11 — Automation surface: human-facing CRUD + occurrence
/// ledger over bt-core's in-process scheduler.
///
/// Layout:
///   - Top header with "+ New automation" button.
///   - Card list of every defined automation. Each card shows its
///     status, schedule cadence, last-run pill, and a `⋯` menu with
///     Pause/Resume, Run-now, Edit, Duplicate, Delete.
///   - Bottom timeline of recent occurrences across every
///     automation. Click a row to expand into status + output +
///     "Retry" (when the row is failed/cancelled).
///
/// All state mutations go through `swift_ui_actor()` on the bt-core
/// side, so every action shows up in the v0.12 audit log with
/// `actor=user_ui`.
struct AutomationSurface: View {
    let domeScope: DomeScopeSelection

    @State private var automations: [DomeRpcClient.Automation] = []
    @State private var occurrences: [DomeRpcClient.AutomationOccurrence] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var editingAutomation: DomeRpcClient.Automation?
    @State private var expandedOccurrenceID: String?
    @State private var actionError: String?
    @State private var deletePending: DomeRpcClient.Automation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(
                title: "Automation",
                subtitle: "\(automations.count) automations · \(domeScope.label)",
                isLoading: isLoading
            ) {
                Task { await reload() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerActions
                    if let err = actionError {
                        errorBanner(err)
                    }
                    if automations.isEmpty {
                        emptyAutomations
                    } else {
                        automationList
                    }
                    occurrenceLedger
                }
                .padding(.horizontal, DK.pageGutter)
                .padding(.vertical, 18)
            }
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reload() }
        .sheet(isPresented: $showCreateSheet) {
            AutomationEditorSheet(
                editing: nil,
                domeScope: domeScope,
                onSave: { result in
                    showCreateSheet = false
                    if result {
                        Task { await reload() }
                    }
                },
                onCancel: { showCreateSheet = false }
            )
        }
        .sheet(item: $editingAutomation) { editing in
            AutomationEditorSheet(
                editing: editing,
                domeScope: domeScope,
                onSave: { result in
                    editingAutomation = nil
                    if result {
                        Task { await reload() }
                    }
                },
                onCancel: { editingAutomation = nil }
            )
        }
    }

    // MARK: - Header

    private var headerActions: some View {
        HStack(spacing: 10) {
            OutlineButton(
                "New automation",
                icon: "plus",
                size: .regular,
                variant: .accent,
                action: { showCreateSheet = true }
            )
            Text("Automations run inside Tado's in-process scheduler. Pause one to stop new occurrences without losing its history.")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Palette.danger)
                .font(.system(size: 12))
            Text(message)
                .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            OutlineButton("Dismiss", size: .small, variant: .ghost) {
                actionError = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.danger.opacity(0.08))
        .overlay(Rectangle().stroke(Palette.danger.opacity(0.4), lineWidth: DK.ruleW))
    }

    // MARK: - Empty state

    private var emptyAutomations: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.ink4)
                Text("No automations yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Click + New automation to schedule recurring agent runs, retro writes, or daily summaries.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("AUTOMATION SCHEDULER  ·  in-process tokio loop  ·  occurrences materialised by scheduler_tick")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - List

    private var automationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OverlineLabel("Automations")
                Spacer()
                Text("\(automations.count) total")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(automations) { automation in
                    automationCard(automation)
                    Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                }
            }
            .background(Palette.bgElev)
            .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
        }
    }

    private func automationCard(_ automation: DomeRpcClient.Automation) -> some View {
        let statusOccurrence = lastOccurrence(for: automation.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(automation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(automation.executorKind)
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                }
                Spacer()
                pausedPill(automation.enabled)
                lastRunPill(statusOccurrence)
                automationActionMenu(automation)
            }

            HStack(spacing: 10) {
                metaTag("Schedule", value: automation.scheduleKind)
                metaTag("Concurrency", value: automation.concurrencyPolicy)
                metaTag("Timezone", value: automation.timezone)
                if let last = automation.lastPlannedAt {
                    metaTag("Last planned", value: Self.relative.localizedString(for: last, relativeTo: Date()))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if !automation.enabled {
                Rectangle().fill(Palette.ink4).frame(width: 2)
            } else if statusOccurrence?.status == "running" {
                Rectangle().fill(Palette.green).frame(width: 2)
            } else if let s = statusOccurrence?.status, s == "failed" || s == "cancelled" {
                Rectangle().fill(Palette.danger).frame(width: 2)
            }
        }
    }

    private func metaTag(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Palette.ink4)
            Text(value)
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
        }
    }

    private func pausedPill(_ enabled: Bool) -> some View {
        StatusPill(
            enabled ? "active" : "paused",
            variant: enabled ? .running : .draft
        )
    }

    private func lastRunPill(_ occurrence: DomeRpcClient.AutomationOccurrence?) -> some View {
        let variant: StatusPill.Variant
        let label: String
        if let o = occurrence {
            label = o.status
            switch o.status {
            case "done":                 variant = .running
            case "failed", "cancelled":  variant = .danger
            case "running":              variant = .planning
            default:                     variant = .review
            }
        } else {
            label = "—"
            variant = .draft
        }
        return StatusPill(label, variant: variant)
    }

    private func automationActionMenu(_ automation: DomeRpcClient.Automation) -> some View {
        Menu {
            Button(automation.enabled ? "Pause" : "Resume") {
                togglePause(automation)
            }
            Button("Run now") {
                runNow(automation)
            }
            Divider()
            Button("Edit") {
                editingAutomation = automation
            }
            Button("Duplicate") {
                duplicate(automation)
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete(automation)
            } label: {
                Text("Delete…")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink3)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Occurrence ledger

    private var occurrenceLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OverlineLabel("Recent occurrences")
                Spacer()
                Text("\(occurrences.count) shown")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.bottom, 10)
            if occurrences.isEmpty {
                Text("Occurrences appear here as automations run. Click Run now on a card above to seed one.")
                    .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(occurrences) { occurrence in
                        occurrenceRow(occurrence)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
                .background(Palette.bgElev)
                .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
            }
        }
    }

    private func occurrenceRow(_ occurrence: DomeRpcClient.AutomationOccurrence) -> some View {
        let isExpanded = expandedOccurrenceID == occurrence.id
        let auto = automations.first(where: { $0.id == occurrence.automationID })
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedOccurrenceID = isExpanded ? nil : occurrence.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 12)
                    statusDot(occurrence.status)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(auto?.title ?? occurrence.automationID)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("\(occurrence.triggerReason) · attempt \(occurrence.attempt)")
                            .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink4)
                    }
                    Spacer()
                    Text(Self.relative.localizedString(for: occurrence.plannedAt, relativeTo: Date()))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                occurrenceDetail(occurrence)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .background(Palette.bgPage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func occurrenceDetail(_ occurrence: DomeRpcClient.AutomationOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Status", value: occurrence.status)
            detailRow("Planned", value: Self.absolute.string(from: occurrence.plannedAt))
            if let started = occurrence.startedAt {
                detailRow("Started", value: Self.absolute.string(from: started))
            }
            if let finished = occurrence.finishedAt {
                detailRow("Finished", value: Self.absolute.string(from: finished))
            }
            if let runID = occurrence.runID {
                detailRow("Run", value: runID)
            }
            if let kind = occurrence.failureKind {
                detailRow("Failure kind", value: kind)
            }
            if let msg = occurrence.failureMessage {
                detailRow("Failure", value: msg)
            }
            if occurrence.status == "failed" || occurrence.status == "cancelled" {
                OutlineButton(
                    "Retry occurrence",
                    icon: "arrow.clockwise",
                    size: .small,
                    variant: .accent,
                    action: { retry(occurrence) }
                )
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Palette.ink4)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer()
        }
    }

    private func statusDot(_ status: String) -> some View {
        let color: Color = {
            switch status {
            case "done": return Palette.green
            case "failed", "cancelled": return Palette.danger
            case "running": return Palette.accent
            default: return Palette.warning
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    // MARK: - Actions

    private func togglePause(_ automation: DomeRpcClient.Automation) {
        let target = !automation.enabled  // user wants to flip the current state
        // automationSetPaused takes paused=true when we want it paused.
        // To pause: target=false (disabled), so paused=true. To resume:
        // target=true (enabled), so paused=false.
        let paused = !target
        Task.detached {
            let result = DomeRpcClient.automationSetPaused(id: automation.id, paused: paused)
            await MainActor.run {
                if result == nil {
                    actionError = "Couldn't toggle pause state — check the daemon log."
                }
            }
            await reload()
        }
    }

    private func runNow(_ automation: DomeRpcClient.Automation) {
        let id = automation.id
        Task.detached {
            let result = DomeRpcClient.automationRunNow(id: id)
            await MainActor.run {
                if result == nil {
                    actionError = "Run now failed. If concurrency is 'serial', wait for the active occurrence to finish."
                }
            }
            await reload()
        }
    }

    private func duplicate(_ automation: DomeRpcClient.Automation) {
        // Round-trip via JSON: fetch the full record, mutate the title,
        // POST as a new record. Keeps payload-shape invariants without
        // re-modeling every executor_config in Swift.
        let id = automation.id
        Task.detached {
            guard var record = DomeRpcClient.automationGetRaw(id: id) else {
                await MainActor.run { actionError = "Couldn't read source automation for duplication." }
                return
            }
            // Strip server-generated fields so bt-core treats this as a
            // brand-new record.
            record.removeValue(forKey: "id")
            record.removeValue(forKey: "created_at")
            record.removeValue(forKey: "updated_at")
            record.removeValue(forKey: "paused_at")
            record.removeValue(forKey: "last_planned_at")
            if let title = record["title"] as? String {
                record["title"] = "\(title) (copy)"
            }
            let created = DomeRpcClient.automationCreate(input: record)
            await MainActor.run {
                if created == nil {
                    actionError = "Duplicate failed — check that all required fields are set."
                }
            }
            await reload()
        }
    }

    private func retry(_ occurrence: DomeRpcClient.AutomationOccurrence) {
        let occurrenceID = occurrence.id
        Task.detached {
            let result = DomeRpcClient.automationRetryOccurrence(occurrenceID: occurrenceID)
            await MainActor.run {
                if result == nil {
                    actionError = "Retry rejected — likely the retry policy's max_attempts cap was reached."
                }
            }
            await reload()
        }
    }

    /// Show a destructive `NSAlert` before deleting. Mirrors the v0.10
    /// codebase-purge guard rail — every destructive action stays
    /// explicitly opt-in.
    private func confirmDelete(_ automation: DomeRpcClient.Automation) {
        let alert = NSAlert()
        alert.messageText = "Delete automation \"\(automation.title)\"?"
        alert.informativeText = "Removes the automation row, its schedule, and its retry policy. Past occurrences in the ledger stay intact for audit."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let id = automation.id
        Task.detached {
            let ok = DomeRpcClient.automationDelete(id: id)
            await MainActor.run {
                if !ok {
                    actionError = "Delete rejected. If the automation has an active occurrence, pause it first and let the occurrence finish."
                }
            }
            await reload()
        }
    }

    // MARK: - Reload

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetchedAutomations = await Task.detached { () -> [DomeRpcClient.Automation] in
            DomeRpcClient.automationList(enabledFilter: .all, executorKind: nil, limit: 200)
        }.value
        let fetchedOccurrences = await Task.detached { () -> [DomeRpcClient.AutomationOccurrence] in
            DomeRpcClient.automationOccurrenceList(automationID: nil, status: nil, from: nil, toISO: nil, limit: 100)
        }.value
        automations = fetchedAutomations
        occurrences = fetchedOccurrences
    }

    private func lastOccurrence(for automationID: String) -> DomeRpcClient.AutomationOccurrence? {
        occurrences
            .filter { $0.automationID == automationID }
            .max { $0.plannedAt < $1.plannedAt }
    }

    // MARK: - Formatters

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - Editor sheet

/// Inline create/edit form. The shape mirrors what bt-core's
/// `build_automation_record` accepts — for the v0.11 surface we
/// expose the high-value fields and defer schedule-payload editing
/// to the JSON textarea so power users can author cron / interval
/// shapes without us shipping a full schedule UI on day one.
private struct AutomationEditorSheet: View {
    let editing: DomeRpcClient.Automation?
    let domeScope: DomeScopeSelection
    let onSave: (Bool) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var executorKind: String = "agent_run"
    @State private var promptTemplate: String = ""
    @State private var scheduleKind: String = "interval"
    @State private var scheduleJSON: String = "{\"every_seconds\": 3600}"
    @State private var executorConfigJSON: String = "{}"
    @State private var retryJSON: String = "{\"max_attempts\": 3, \"backoff_seconds\": 60}"
    @State private var concurrency: String = "serial"
    @State private var timezone: String = "UTC"
    @State private var enabled: Bool = true
    @State private var saveError: String?
    @State private var saving = false

    private static let executorKinds = ["agent_run", "note_write", "dispatch", "shell"]
    private static let scheduleKinds = ["interval", "cron", "fixed_time"]
    private static let concurrencyPolicies = ["serial", "parallel", "skip_if_active"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    OverlineLabel(editing == nil ? "New automation" : "Edit automation")
                    Text(editing?.title ?? "Untitled automation")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(Palette.ink)
                }
                Spacer()
                StatusPill(enabled ? "active" : "paused", variant: enabled ? .running : .draft)
            }
            .padding(.bottom, 4)
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)

            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Executor", selection: $executorKind) {
                        ForEach(Self.executorKinds, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Enabled", isOn: $enabled)
                }

                Section("Prompt template") {
                    TextEditor(text: $promptTemplate)
                        .font(Typography.monoCaption)
                        .frame(minHeight: 80)
                }

                Section("Schedule") {
                    Picker("Kind", selection: $scheduleKind) {
                        ForEach(Self.scheduleKinds, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Schedule JSON")
                        .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    TextEditor(text: $scheduleJSON)
                        .font(Typography.monoCaption)
                        .frame(minHeight: 60)
                }

                Section("Concurrency & retry") {
                    Picker("Concurrency", selection: $concurrency) {
                        ForEach(Self.concurrencyPolicies, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Timezone", text: $timezone)
                    Text("Retry policy JSON")
                        .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    TextEditor(text: $retryJSON)
                        .font(Typography.monoCaption)
                        .frame(minHeight: 50)
                }

                Section("Executor config") {
                    Text("JSON forwarded to the executor as-is. agent_run wants `{ \"agent_name\": \"...\", \"prompt\": \"...\" }`.")
                        .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    TextEditor(text: $executorConfigJSON)
                        .font(Typography.monoCaption)
                        .frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)

            if let err = saveError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(Palette.danger)
                        .font(.system(size: 11))
                    Text(err)
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.danger.opacity(0.08))
                .overlay(Rectangle().stroke(Palette.danger.opacity(0.4), lineWidth: DK.ruleW))
            }

            HStack {
                Spacer()
                OutlineButton("Cancel", size: .regular, variant: .ghost, action: onCancel)
                OutlineButton(
                    saving ? "Saving…" : (editing == nil ? "Create" : "Save"),
                    icon: "checkmark.circle",
                    size: .regular,
                    variant: .accent,
                    action: save
                )
                .keyboardShortcut(.defaultAction)
                .disabled(saving || title.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 600)
        .background(Palette.bgPage)
        .onAppear { hydrate() }
    }

    private func hydrate() {
        guard let editing else { return }
        title = editing.title
        executorKind = editing.executorKind
        promptTemplate = editing.promptTemplate
        scheduleKind = editing.scheduleKind
        concurrency = editing.concurrencyPolicy
        timezone = editing.timezone
        enabled = editing.enabled
        // The JSON envelopes aren't on the Automation Codable struct
        // (we kept the shape lean). Hydrate them from a fresh `get`
        // so edits don't lose existing schedule/retry config.
        let editingID = editing.id
        Task.detached {
            guard let record = DomeRpcClient.automationGetRaw(id: editingID) else { return }
            await MainActor.run {
                if let s = record["schedule_json"] as? [String: Any],
                   let bytes = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted]),
                   let str = String(data: bytes, encoding: .utf8) {
                    scheduleJSON = str
                }
                if let r = record["retry_policy_json"] as? [String: Any],
                   let bytes = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted]),
                   let str = String(data: bytes, encoding: .utf8) {
                    retryJSON = str
                }
                if let e = record["executor_config_json"] as? [String: Any],
                   let bytes = try? JSONSerialization.data(withJSONObject: e, options: [.prettyPrinted]),
                   let str = String(data: bytes, encoding: .utf8) {
                    executorConfigJSON = str
                }
            }
        }
    }

    private func save() {
        guard let scheduleObj = parseJSON(scheduleJSON) else {
            saveError = "Schedule JSON must be a valid JSON object."
            return
        }
        guard let retryObj = parseJSON(retryJSON) else {
            saveError = "Retry policy JSON must be a valid JSON object."
            return
        }
        guard let execObj = parseJSON(executorConfigJSON) else {
            saveError = "Executor config JSON must be a valid JSON object."
            return
        }
        var payload: [String: Any] = [
            "title": title,
            "executor_kind": executorKind,
            "prompt_template": promptTemplate,
            "schedule_kind": scheduleKind,
            "schedule_json": scheduleObj,
            "retry_policy_json": retryObj,
            "executor_config_json": execObj,
            "concurrency_policy": concurrency,
            "timezone": timezone,
            "enabled": enabled,
        ]
        // Carry the project_id so scheduler-aware filters know where the
        // automation belongs. Optional for now — not every automation
        // is project-scoped.
        if let pid = domeScope.projectIDString {
            payload["project_id"] = pid
        }
        saving = true
        saveError = nil
        let editingID = editing?.id
        Task.detached {
            let result: DomeRpcClient.Automation? = {
                if let editingID {
                    return DomeRpcClient.automationUpdate(id: editingID, patch: payload)
                } else {
                    return DomeRpcClient.automationCreate(input: payload)
                }
            }()
            await MainActor.run {
                saving = false
                if result == nil {
                    saveError = "Save rejected by bt-core. Common causes: required fields missing, invalid schedule shape, doc_id pointing at a deleted doc."
                } else {
                    onSave(true)
                }
            }
        }
    }

    private func parseJSON(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [String: Any]() }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
