import Foundation
import Observation

@MainActor
@Observable
final class FocusService {
    private(set) var dailySessions: [FocusSession] = []
    private(set) var summary: FocusSummary?
    private(set) var morningMessage: MorningMessage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var dataVersion = 0
    private(set) var pendingSessions: [PendingFocusSession] = []

    private let client: APIClient
    private let pendingStore: PendingFocusSessionStore
    private var pendingUserID: UUID?
    private var isFlushing = false

    init(client: APIClient? = nil, pendingStore: PendingFocusSessionStore? = nil) {
        self.client = client ?? APIClient()
        self.pendingStore = pendingStore ?? PendingFocusSessionStore()
        refreshPendingAccount()
    }

    private func refreshPendingAccount() {
        let userID = client.userID
        guard userID != pendingUserID else { return }
        pendingUserID = userID
        pendingSessions = userID.map { pendingStore.load(userID: $0) } ?? []
    }

    func loadFocus(after: Date? = nil, before: Date? = nil) async {
        isLoading = true
        defer { isLoading = false }
        async let sessions = loadSessions(after: after, before: before)
        async let summary = loadSummary(after: after, before: before)
        _ = await (sessions, summary)
    }

    @discardableResult
    func createSession(
        taskID: UUID?,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int? = nil,
        category: String? = nil
    ) async -> FocusSession? {
        refreshPendingAccount()
        guard let userID = client.userID else {
            errorMessage = "Sign in before logging a focus session."
            return nil
        }
        errorMessage = nil
        let operation = PendingFocusSession(
            id: UUID(),
            taskID: taskID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            category: category
        )
        do {
            let session: FocusSession = try await client.request(FocusEndpoint.create(operation.createPayload))
            guard client.userID == userID else { return nil }
            dataVersion += 1
            await loadFocus()
            return session
        } catch {
            guard Self.shouldQueue(error) else {
                errorMessage = error.localizedDescription
                return nil
            }
            // Reuse the first POST's ID if its outcome was ambiguous.
            enqueuePending(operation, userID: userID)
            errorMessage = "Focus session saved on this device. It will sync when you're back online."
            return nil
        }
    }

    /// Uploads every locally queued focus session.
    ///
    /// Called when the app returns to the foreground and after a successful
    /// token refresh so sessions recorded while offline or while the session
    /// had lapsed are not silently dropped.
    func flushPendingSessions() async {
        guard !isFlushing else { return }
        refreshPendingAccount()
        guard let userID = pendingUserID else { return }
        let pending = pendingSessions
        guard !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        var didChange = false
        var rejectedError: String?
        for queued in pending {
            guard client.userID == userID else { refreshPendingAccount(); return }
            do {
                _ = try await client.request(FocusEndpoint.create(queued.createPayload)) as FocusSession
                guard client.userID == userID else { refreshPendingAccount(); return }
                didChange = true
                pendingSessions.removeAll { $0.id == queued.id }
                pendingStore.save(pendingSessions, userID: userID)
            } catch {
                guard client.userID == userID else { refreshPendingAccount(); return }
                if !Self.shouldQueue(error) {
                    pendingSessions.removeAll { $0.id == queued.id }
                    pendingStore.save(pendingSessions, userID: userID)
                    didChange = true
                    rejectedError = "A focus session could not sync: \(error.localizedDescription)"
                }
            }
        }

        guard client.userID == userID else { refreshPendingAccount(); return }
        if didChange {
            errorMessage = nil
            dataVersion += 1
            await loadFocus()
        }
        if let rejectedError {
            errorMessage = rejectedError
        } else if !pendingSessions.isEmpty {
            errorMessage = "Some focus sessions are waiting to sync."
        }
    }

    static func shouldQueue(_ error: Error) -> Bool {
        if let error = error as? NetworkError {
            switch error {
            case .httpStatus(let status), .serverError(let status, _):
                return [408, 425, 429].contains(status) || (500..<600).contains(status)
            case .invalidResponse, .decoding:
                // A POST may have committed even if its response was unusable.
                return true
            case .unauthorized:
                return false
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cancelled:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func enqueuePending(_ session: PendingFocusSession, userID: UUID) {
        guard client.userID == userID else {
            var saved = pendingStore.load(userID: userID)
            saved.append(session)
            pendingStore.save(saved, userID: userID)
            refreshPendingAccount()
            return
        }
        guard !pendingSessions.contains(where: { $0.id == session.id }) else { return }
        pendingSessions.append(session)
        pendingStore.save(pendingSessions, userID: userID)
    }

    @discardableResult
    func updateSession(
        id: UUID,
        startedAt: Date?,
        endedAt: Date?
    ) async -> FocusSession? {
        let payload = FocusSessionUpdate(startedAt: startedAt, endedAt: endedAt)
        do {
            let session: FocusSession = try await client.request(
                FocusEndpoint.update(id: id, payload)
            )
            dataVersion += 1
            await loadFocus()
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteSession(id: UUID) async -> Bool {
        do {
            _ = try await client.request(FocusEndpoint.delete(id)) as MessageResponse
            dailySessions.removeAll { $0.id == id }
            dataVersion += 1
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func loadMorningMessage() async -> MorningMessage? {
        do {
            let message: MorningMessage = try await client.request(FocusEndpoint.morningMessage)
            morningMessage = message
            dataVersion += 1
            return message
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func loadSessions(after: Date? = nil, before: Date? = nil) async {
        do {
            let response: [FocusSession] = try await client.request(
                FocusEndpoint.sessions(after: after, before: before)
            )
            dailySessions = response
            dataVersion += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSummary(after: Date? = nil, before: Date? = nil) async {
        do {
            let response: FocusSummary = try await client.request(
                FocusEndpoint.summary(after: after, before: before)
            )
            summary = response
            dataVersion += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A focus session that was stopped locally but could not be uploaded yet.
struct PendingFocusSession: Codable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID?
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int?
    let category: String?

    var createPayload: FocusSessionCreate {
        FocusSessionCreate(
            sessionID: id, recordTaskTime: true, taskID: taskID,
            startedAt: startedAt, endedAt: endedAt,
            durationSeconds: durationSeconds, category: category
        )
    }

    init(
        id: UUID = UUID(),
        taskID: UUID?,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int?,
        category: String?
    ) {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.category = category
    }
}

/// Durable file-backed store for focus sessions waiting to sync.
final class PendingFocusSessionStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("MyApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("PendingFocusSessions.json")
    }

    private func scopedURL(userID: UUID) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent)-\(userID.uuidString).json"
        )
    }

    func load(userID: UUID) -> [PendingFocusSession] {
        // Legacy unscoped files cannot be attributed safely and are never replayed.
        guard let data = try? Data(contentsOf: scopedURL(userID: userID)),
              let sessions = try? JSONDecoder().decode([PendingFocusSession].self, from: data) else {
            return []
        }
        return sessions
    }

    func save(_ sessions: [PendingFocusSession], userID: UUID) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: scopedURL(userID: userID), options: .atomic)
    }
}
