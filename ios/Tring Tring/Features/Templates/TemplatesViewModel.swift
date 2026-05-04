//
//  TemplatesViewModel.swift
//  Tring Tring
//

import Foundation
import OSLog

@Observable
@MainActor
final class TemplatesViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case populated
        case empty
        case error(String)
    }

    private static let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "templates")

    var state: LoadState = .idle
    var templates: [Template] = []
    var transientError: String?

    private var inFlight: Task<Void, Never>?
    private let client: BackendClient

    init(client: BackendClient? = nil) {
        self.client = client ?? .shared
    }

    func load(bearer: String) async {
        inFlight?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.performLoad(bearer: bearer)
        }
        inFlight = task
        await task.value
    }

    @discardableResult
    func save(
        bearer: String,
        name: String,
        payload: OutgoingNotification
    ) async throws -> Template {
        if let forbidden = TemplateValidation.validate(payload) {
            throw TemplateError.forbiddenKey(forbidden)
        }
        let saved = try await client.putTemplate(bearer: bearer, name: name, payload: payload)
        upsert(saved)
        return saved
    }

    func delete(bearer: String, name: String) async throws {
        try await client.deleteTemplate(bearer: bearer, name: name)
        templates.removeAll { $0.name == name }
        if templates.isEmpty {
            state = .empty
        }
    }

    func sendNow(
        webhookBase: URL,
        userId: String,
        name: String,
        payload: OutgoingNotification
    ) async throws {
        _ = try await client.sendViaWebhook(
            webhookBase: webhookBase,
            userId: userId,
            name: name,
            payload: payload
        )
    }

    func dismissTransientError() {
        transientError = nil
    }

    private func performLoad(bearer: String) async {
        if templates.isEmpty {
            state = .loading
        }
        do {
            let response = try await client.listTemplates(bearer: bearer)
            if Task.isCancelled { return }
            templates = response.templates.sorted { $0.updatedAt > $1.updatedAt }
            transientError = nil
            state = templates.isEmpty ? .empty : .populated
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.error("load failed: \(message, privacy: .public)")
            if templates.isEmpty {
                state = .error(message)
            } else {
                transientError = message
            }
        }
    }

    private func upsert(_ template: Template) {
        if let index = templates.firstIndex(where: { $0.name == template.name }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        templates.sort { $0.updatedAt > $1.updatedAt }
        state = templates.isEmpty ? .empty : .populated
    }
}

enum TemplateError: LocalizedError, Equatable {
    case forbiddenKey(String)
    case invalidName
    case invalidActionName(String)
    case invalidBackgroundOptions
    case duplicateActionNames

    var errorDescription: String? {
        switch self {
        case .forbiddenKey(let key):
            return "Templates cannot include \(key)."
        case .invalidName:
            return "Name must match A–Z, 0–9, dot, underscore, dash (1–64 chars)."
        case .invalidActionName(let name):
            return "Action name \"\(name)\" is invalid (1–32 chars; letters, digits, dot, underscore, dash, space)."
        case .invalidBackgroundOptions:
            return "Background options must be a valid JSON object."
        case .duplicateActionNames:
            return "Action names must be unique within a template."
        }
    }
}
