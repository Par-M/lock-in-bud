import Foundation
import Observation

@MainActor
@Observable
final class ScheduleService {
    private(set) var proposal: ScheduleProposal?
    private(set) var blocks: [CalendarBlock] = []
    private(set) var preference: UserPreference?
    private(set) var isGenerating = false
    private(set) var isSyncing = false
    private(set) var errorMessage: String?
    private var isAccepting = false

    private let client: APIClient
    private let store: LocalStore?
    private let connectivity: ConnectivityMonitor

    init(
        client: APIClient? = nil,
        store: LocalStore? = nil,
        connectivity: ConnectivityMonitor? = nil
    ) {
        self.client = client ?? APIClient()
        self.store = store
        self.connectivity = connectivity ?? ConnectivityMonitor()
    }

    func loadBlocks() async {
        do {
            let response: CalendarBlockListResponse = try await client.request(
                CalendarEndpoint.listBlocks()
            )
            blocks = response.items.sorted { $0.startAt < $1.startAt }
            store?.upsertServerBlocks(response.items)
        } catch {
            if let store, isNetworkUnavailable(error) || !connectivity.isConnected {
                blocks = store.blocks()
                errorMessage = "Offline — showing saved schedule."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    func loadPreferences() async {
        do {
            preference = try await client.request(PreferenceEndpoint.get)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePreferences(_ update: UserPreferenceUpdate) async {
        do {
            preference = try await client.request(PreferenceEndpoint.update(update))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate(startDate: Date, endDate: Date, busyTimes: [BusyTimeRequest] = []) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let request = ScheduleGenerateRequest(
                startDate: startDate,
                endDate: endDate,
                timezone: TimeZone.current.identifier,
                busyTimes: busyTimes
            )
            let response: ScheduleProposal = try await client.request(
                ScheduleEndpoint.generate(request)
            )
            proposal = response
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accept(_ target: ScheduleProposal) async throws {
        guard !isAccepting else { return }
        isAccepting = true
        defer { isAccepting = false }
        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }
        let response: AcceptResponse = try await client.request(
            ScheduleEndpoint.accept(target.id)
        )
        if proposal?.id == target.id {
            proposal = nil
        }
        try await syncBlocks(response.blocks)
        await loadBlocks()
    }

    func reject(_ target: ScheduleProposal) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        errorMessage = nil
        do {
            _ = try await client.request(ScheduleEndpoint.reject(target.id)) as RecommendationResponse
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if proposal?.id == target.id {
            proposal = nil
        }
        return true
    }

    func acceptItem(_ target: ScheduleProposal, item: ScheduleItem) async throws {
        guard let index = target.items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }
        let response: AcceptResponse = try await client.request(
            ScheduleEndpoint.acceptItem(recommendationID: target.id, itemIndex: index)
        )
        updateProposal(with: response.recommendation)
        try await syncBlocks(response.blocks)
        await loadBlocks()
    }

    func redoItem(_ target: ScheduleProposal, item: ScheduleItem) async throws {
        guard let index = target.items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }
        let response: RecommendationResponse = try await client.request(
            ScheduleEndpoint.redoItem(recommendationID: target.id, itemIndex: index)
        )
        updateProposal(with: response)
    }

    private func updateProposal(with response: RecommendationResponse) {
        guard proposal?.id == response.id else { return }
        proposal = ScheduleProposal(
            id: response.id,
            status: response.status,
            accepted: response.accepted,
            reasoning: response.reasoning,
            items: response.items,
            meta: response.meta,
            failureReason: response.failureReason,
            retryAt: response.retryAt,
            createdAt: response.createdAt,
            message: proposal?.message
        )
    }

    func updateBlockTime(_ block: CalendarBlock, start: Date, end: Date) async throws {
        if !connectivity.isConnected, let store {
            let local = CalendarBlock(
                id: block.id,
                userId: block.userId,
                taskId: block.taskId,
                calendarEventId: block.calendarEventId,
                title: block.title,
                startAt: start,
                endAt: end,
                completedAt: block.completedAt,
                completionNote: block.completionNote,
                createdAt: block.createdAt,
                updatedAt: Date()
            )
            store.upsert(local, dirty: true)
            if let index = blocks.firstIndex(where: { $0.id == block.id }) {
                blocks[index] = local
            }
            return
        }

        let request = CalendarBlockUpdateRequest(startAt: start, endAt: end)
        let updated: CalendarBlock = try await client.request(
            CalendarEndpoint.updateBlock(id: block.id, request: request)
        )
        store?.upsert(updated)
        if let index = blocks.firstIndex(where: { $0.id == updated.id }) {
            blocks[index] = updated
        }
    }

    func deleteBlock(_ block: CalendarBlock) async throws {
        if !connectivity.isConnected, let store {
            store.markDeleted(blockId: block.id)
        } else {
            do {
                _ = try await client.request(CalendarEndpoint.deleteBlock(block.id)) as MessageResponse
                store?.purgeBlock(id: block.id)
            } catch NetworkError.httpStatus(404) {
                store?.purgeBlock(id: block.id)
            } catch {
                if let store, isNetworkUnavailable(error) {
                    store.markDeleted(blockId: block.id)
                } else {
                    throw error
                }
            }
        }
        blocks.removeAll { $0.id == block.id }
    }

    func completeBlock(_ block: CalendarBlock, note: String?) async throws -> CalendarBlock {
        let updated: CalendarBlock = try await client.request(
            CalendarEndpoint.completeBlock(id: block.id, note: note)
        )
        store?.upsert(updated)
        replaceBlock(updated)
        return updated
    }

    func reopenBlock(_ block: CalendarBlock) async throws -> CalendarBlock {
        let updated: CalendarBlock = try await client.request(
            CalendarEndpoint.reopenBlock(block.id)
        )
        store?.upsert(updated)
        replaceBlock(updated)
        return updated
    }

    private func replaceBlock(_ block: CalendarBlock) {
        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[index] = block
        } else {
            blocks.append(block)
        }
    }

    private func syncBlocks(_ newBlocks: [CalendarBlock]) async throws {
        blocks = newBlocks
    }
}
