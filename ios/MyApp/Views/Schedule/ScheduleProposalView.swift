import SwiftUI

struct ScheduleProposalView: View {
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(\.dismiss) private var dismiss

    @State private var redoingItemID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = scheduleService.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if let message = scheduleService.proposal?.message {
                        Label(message, systemImage: "sparkles")
                            .font(.headline)
                    }

                    if let proposal = scheduleService.proposal {
                        if proposal.items.isEmpty {
                            ContentUnavailableView(
                                "Nothing to Schedule",
                                systemImage: "calendar.badge.exclamationmark",
                                description: Text(
                                    proposal.failureReason ?? "No tasks could be placed in this window."
                                )
                            )
                        } else {
                            ForEach(proposal.items.filter { !$0.accepted }) { item in
                                proposalItemRow(item)
                            }
                        }

                        if proposal.meta.overcommitted {
                            overcommitmentBanner(proposal.meta)
                        }

                        if let reasoning = proposal.reasoning, !reasoning.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI Reasoning")
                                    .font(.subheadline.bold())
                                Text(reasoning)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Proposed Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let proposal = scheduleService.proposal {
                    bottomBar(proposal)
                }
            }
        }
    }

    private func proposalItemRow(_ item: ScheduleItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.taskTitle)
                            .font(.headline)
                        if item.accepted {
                            Label("Approved", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(item.start.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !item.reason.isEmpty {
                        Text(item.reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                itemActions(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.accentColor.opacity(item.accepted ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 12))
        .opacity(item.accepted ? 0.75 : 1)
    }

    @ViewBuilder
    private func itemActions(_ item: ScheduleItem) -> some View {
        let isBusy = scheduleService.isSyncing || redoingItemID != nil
        if item.accepted {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        } else if redoingItemID == item.id {
            ProgressView()
                .controlSize(.small)
        } else {
            VStack(spacing: 6) {
                Button {
                    Task { await approve(item) }
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)

                Button {
                    Task { await redo(item) }
                } label: {
                    Label("Redo", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func bottomBar(_ proposal: ScheduleProposal) -> some View {
        let pendingCount = proposal.items.filter { !$0.accepted }.count
        let allAccepted = proposal.status != .pending || pendingCount == 0
        return HStack(spacing: 12) {
            Button {
                Task { await reject(proposal) }
            } label: {
                Text("Reject")
            }
            .buttonStyle(.bordered)
            .disabled(scheduleService.isSyncing || allAccepted)

            if allAccepted {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await accept(proposal) }
                } label: {
                    if scheduleService.isSyncing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Accept All (\(pendingCount))")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduleService.isSyncing || proposal.items.isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func overcommitmentBanner(_ meta: ScheduleMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not enough free time", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            if let risk = meta.risk {
                Text(risk)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !meta.deferredTasks.isEmpty {
                Text("Deferred: \(meta.deferredTasks.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func approve(_ item: ScheduleItem) async {
        guard let proposal = scheduleService.proposal else { return }
        do {
            try await scheduleService.acceptItem(proposal, item: item)
        } catch {
            scheduleService.presentError(error.localizedDescription)
        }
    }

    private func redo(_ item: ScheduleItem) async {
        guard let proposal = scheduleService.proposal else { return }
        redoingItemID = item.id
        defer { redoingItemID = nil }
        do {
            try await scheduleService.redoItem(proposal, item: item)
        } catch {
            scheduleService.presentError(error.localizedDescription)
        }
    }

    private func accept(_ proposal: ScheduleProposal) async {
        do {
            try await scheduleService.accept(proposal)
            dismiss()
        } catch {
            scheduleService.presentError(error.localizedDescription)
        }
    }

    private func reject(_ proposal: ScheduleProposal) async {
        if await scheduleService.reject(proposal) { dismiss() }
    }
}

#Preview {
    ScheduleProposalView()
        .environment(ScheduleService())
}
