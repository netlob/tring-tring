//
//  TemplateEditorSheet.swift
//  Tring Tring
//

import SwiftUI

struct TemplateEditorSheet: View {
    let existing: Template?
    let bearer: String
    let userId: String
    let webhookBase: URL
    let viewModel: TemplatesViewModel
    let onSaved: (Template) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var title: String = ""
    @State private var text: String = ""
    @State private var soundName: String = "default"
    @State private var threadId: String = ""
    @State private var isTimeSensitive: Bool = false
    @State private var defaultActionURL: String = ""
    @State private var defaultActionOptionsJSON: String = ""
    @State private var actions: [ActionPayload] = []

    @State private var showSoundPicker = false
    @State private var showDeleteConfirm = false
    @State private var defaultActionExpanded = false
    @State private var actionsExpanded = true

    @State private var saveError: String?
    @State private var sendError: String?
    @State private var isSaving = false
    @State private var isSending = false
    @State private var sentToast = false
    @State private var sentToastTask: Task<Void, Never>?

    private var isEditing: Bool { existing != nil }
    private var actionsLimitReached: Bool { actions.count >= 3 }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        ErrorBanner(message: saveError) {
                            self.saveError = nil
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if let sendError {
                    Section {
                        ErrorBanner(message: sendError) {
                            self.sendError = nil
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                identitySection
                soundSection
                behaviourSection
                defaultActionSection
                actionsSection

                if isEditing {
                    Section {
                        sendNowButton
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Template", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Template" : "New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if sentToast {
                    sentToastView
                        .padding(.bottom, Theme.spacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: sentToast)
            .sheet(isPresented: $showSoundPicker) {
                SoundPickerSheet(selection: $soundName)
            }
            .confirmationDialog(
                "Delete this template?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the template from the server.")
            }
        }
        .presentationBackground(.thinMaterial)
        .presentationDetents([.large])
        .onAppear(perform: hydrate)
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isEditing)
                .foregroundStyle(isEditing ? .secondary : .primary)
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            TextField("Title", text: $title)
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private var soundSection: some View {
        Section("Sound") {
            Button {
                showSoundPicker = true
            } label: {
                HStack {
                    Text(SoundCatalog.displayLabel(for: soundName))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var behaviourSection: some View {
        Section("Behaviour") {
            Toggle("Time-sensitive", isOn: $isTimeSensitive)
            TextField("Thread ID", text: $threadId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var defaultActionSection: some View {
        Section {
            DisclosureGroup(isExpanded: $defaultActionExpanded) {
                TextField("URL", text: $defaultActionURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Background options JSON (optional)", text: $defaultActionOptionsJSON, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let optionsError {
                    Text(optionsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } label: {
                Text("Default action")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $actionsExpanded) {
                if actions.isEmpty {
                    Text("No actions yet. Add up to three.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { pair in
                        ActionEditorRow(
                            action: binding(for: pair.element.id),
                            index: pair.offset,
                            onDelete: { remove(actionId: pair.element.id) }
                        )
                    }
                    .onMove(perform: moveActions)
                }

                Button {
                    appendAction()
                } label: {
                    Label("Add action", systemImage: "plus.circle")
                }
                .disabled(actionsLimitReached)
                .foregroundStyle(actionsLimitReached ? Color.secondary : Color.brass)
            } label: {
                HStack {
                    Text("Actions")
                    Spacer()
                    Text("\(actions.count)/3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var sendNowButton: some View {
        Button {
            Task { await sendNow() }
        } label: {
            HStack {
                Spacer()
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text(isSending ? "Sending..." : "Send now")
                Spacer()
            }
            .padding(.vertical, Theme.spacing.xs)
        }
        .buttonStyle(.glassProminent)
        .tint(.brass)
        .disabled(isSending)
    }

    private var sentToastView: some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.brass)
            Text("Sent")
                .font(Theme.typography.cardTitle())
        }
        .padding(.horizontal, Theme.spacing.lg)
        .padding(.vertical, Theme.spacing.md)
        .glassEffect(
            .regular.tint(Color.brass.opacity(0.25)),
            in: .capsule
        )
    }

    private var nameError: String? {
        guard !name.isEmpty else { return nil }
        return NameValidation.isValidNotificationName(name) ? nil : "Use 1–64 chars: letters, digits, dot, underscore, dash."
    }

    private var optionsError: String? {
        guard !defaultActionOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parseOptions() == nil ? "Invalid JSON object." : nil
    }

    private var canSave: Bool {
        guard NameValidation.isValidNotificationName(name) else { return false }
        if let error = optionsError, !error.isEmpty { return false }
        for action in actions {
            if let n = action.name, !n.isEmpty, !NameValidation.isValidActionName(n) {
                return false
            }
        }
        return true
    }

    private func hydrate() {
        guard let existing else {
            soundName = "default"
            return
        }
        name = existing.name
        let payload = existing.defaultPayload
        title = payload.title ?? ""
        text = payload.text ?? ""
        soundName = payload.sound ?? "default"
        threadId = payload.threadId ?? ""
        isTimeSensitive = payload.isTimeSensitive ?? false
        defaultActionURL = payload.defaultAction?.url ?? ""
        if let opts = payload.defaultAction?.urlBackgroundOptions {
            defaultActionOptionsJSON = encodeAnyCodable(opts)
            defaultActionExpanded = true
        }
        actions = payload.actions ?? []
    }

    private func binding(for id: UUID) -> Binding<ActionPayload> {
        Binding(
            get: { actions.first(where: { $0.id == id }) ?? ActionPayload(id: id) },
            set: { newValue in
                if let index = actions.firstIndex(where: { $0.id == id }) {
                    actions[index] = newValue
                }
            }
        )
    }

    private func appendAction() {
        guard !actionsLimitReached else { return }
        actions.append(ActionPayload())
        HapticFeedback.light.fire()
    }

    private func remove(actionId: UUID) {
        actions.removeAll { $0.id == actionId }
        HapticFeedback.light.fire()
    }

    private func moveActions(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
    }

    private func parseOptions() -> AnyCodable? {
        let trimmed = defaultActionOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(AnyCodable.self, from: data) else {
            return nil
        }
        if case .object = value { return value }
        return nil
    }

    private func encodeAnyCodable(_ value: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    private func buildPayload() throws -> OutgoingNotification {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThread = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefaultURL = defaultActionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOptions = defaultActionOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)

        var defaultAction: DefaultActionPayload?
        if !trimmedDefaultURL.isEmpty || !trimmedOptions.isEmpty {
            var options: AnyCodable?
            if !trimmedOptions.isEmpty {
                guard let parsed = parseOptions() else {
                    throw TemplateError.invalidBackgroundOptions
                }
                options = parsed
            }
            defaultAction = DefaultActionPayload(
                url: trimmedDefaultURL.isEmpty ? nil : trimmedDefaultURL,
                urlBackgroundOptions: options
            )
        }

        var cleanedActions: [ActionPayload] = []
        var seenNames = Set<String>()
        for action in actions {
            if let n = action.name, !n.isEmpty {
                guard NameValidation.isValidActionName(n) else {
                    throw TemplateError.invalidActionName(n)
                }
                if !seenNames.insert(n).inserted {
                    throw TemplateError.duplicateActionNames
                }
            }
            cleanedActions.append(action)
        }

        return OutgoingNotification(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            text: trimmedText.isEmpty ? nil : trimmedText,
            sound: soundName == "default" && existing == nil ? nil : soundName,
            threadId: trimmedThread.isEmpty ? nil : trimmedThread,
            isTimeSensitive: isTimeSensitive ? true : nil,
            defaultAction: defaultAction,
            devices: nil,
            actions: cleanedActions.isEmpty ? nil : cleanedActions
        )
    }

    private func save() async {
        guard NameValidation.isValidNotificationName(name) else {
            saveError = TemplateError.invalidName.errorDescription
            return
        }
        let payload: OutgoingNotification
        do {
            payload = try buildPayload()
        } catch let error as TemplateError {
            saveError = error.errorDescription
            return
        } catch {
            saveError = error.localizedDescription
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await viewModel.save(bearer: bearer, name: name, payload: payload)
            HapticFeedback.success.fire()
            onSaved(saved)
            dismiss()
        } catch let error as TemplateError {
            saveError = error.errorDescription
            HapticFeedback.warning.fire()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            HapticFeedback.warning.fire()
        }
    }

    private func performDelete() async {
        guard isEditing else { return }
        do {
            try await viewModel.delete(bearer: bearer, name: name)
            HapticFeedback.warning.fire()
            dismiss()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func sendNow() async {
        guard isEditing else { return }
        let payload: OutgoingNotification
        do {
            payload = try buildPayload()
        } catch let error as TemplateError {
            sendError = error.errorDescription
            return
        } catch {
            sendError = error.localizedDescription
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await viewModel.sendNow(
                webhookBase: webhookBase,
                userId: userId,
                name: name,
                payload: payload
            )
            HapticFeedback.success.fire()
            sendError = nil
            showSentToast()
        } catch {
            HapticFeedback.warning.fire()
            sendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func showSentToast() {
        sentToastTask?.cancel()
        sentToast = true
        sentToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                sentToast = false
            }
        }
    }
}
