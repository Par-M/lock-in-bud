import SwiftUI

struct ScheduleProposalView: View {
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(\.dismiss) private var dismiss

    @State private var redoingItemID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppHeader(eyebrow: "SCHEDULE", title: "Your proposed day.")

                    if let error = scheduleService.errorMessage {
                        AppCard(padding: 14) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let message = scheduleService.proposal?.message {
                        AppCard(padding: 14) {
                            Label(message, systemImage: "sparkles")
                                .font(DesignPalette.body(15).weight(.semibold))
                                .foregroundStyle(DesignPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let proposal = scheduleService.proposal {
                        let remaining = proposal.items.filter { !$0.accepted }.count
                        VStack(alignment: .leading, spacing: 6) {
                            AppEyebrow(text: "REVIEW BEFORE APPLYING")
                            Text("Adds \(remaining) proposed time blocks. Fixed events keep their times. Review each placement below; approving does not mark tasks complete.")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(DesignPalette.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

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
                            AppCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("AI Reasoning")
                                        .font(DesignPalette.body(13).weight(.semibold))
                                        .foregroundStyle(DesignPalette.ink)
                                    Text(reasoning)
                                        .font(DesignPalette.body(12))
                                        .foregroundStyle(DesignPalette.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Proposed Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
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
        AppCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.taskTitle)
                                .font(DesignPalette.body(15).weight(.semibold))
                                .foregroundStyle(DesignPalette.ink)
                            if item.accepted {
                                Label("Approved", systemImage: "checkmark.circle.fill")
                                    .font(DesignPalette.body(11).weight(.semibold))
                                    .foregroundStyle(DesignPalette.primary)
                            }
                        }
                        Text(item.start.formatted(date: .abbreviated, time: .omitted))
                            .font(DesignPalette.body(11))
                            .foregroundStyle(DesignPalette.secondary)
                        Text("\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                            .font(DesignPalette.body(11))
                            .foregroundStyle(DesignPalette.secondary)
                        if !item.reason.isEmpty {
                            Text(item.reason)
                                .font(DesignPalette.body(12))
                                .foregroundStyle(DesignPalette.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    itemActions(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(item.accepted ? 0.75 : 1)
    }

    @ViewBuilder
    private func itemActions(_ item: ScheduleItem) -> some View {
        let isBusy = scheduleService.isSyncing || redoingItemID != nil
        if item.accepted {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(DesignPalette.primary)
        } else if redoingItemID == item.id {
            ProgressView()
                .controlSize(.small)
                .tint(DesignPalette.primary)
        } else {
            VStack(spacing: 6) {
                Button {
                    Task { await approve(item) }
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .font(DesignPalette.body(11).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppSecondaryButtonStyle())
                .frame(width: 100)
                .disabled(isBusy)

                Button {
                    Task { await redo(item) }
                } label: {
                    Label("Redo", systemImage: "arrow.clockwise")
                        .font(DesignPalette.body(11).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppSecondaryButtonStyle())
                .frame(width: 100)
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppSecondaryButtonStyle())
            .disabled(scheduleService.isSyncing || allAccepted)

            if allAccepted {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppPrimaryButtonStyle())
            } else {
                Button {
                    Task { await accept(proposal) }
                } label: {
                    if scheduleService.isSyncing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .tint(.white)
                    } else {
                        Text("Accept All (\(pendingCount))")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .disabled(scheduleService.isSyncing || proposal.items.isEmpty)
            }
        }
        .padding()
        .background(DesignPalette.background)
    }

    private func overcommitmentBanner(_ meta: ScheduleMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not enough free time", systemImage: "exclamationmark.triangle.fill")
                .font(DesignPalette.body(13).weight(.semibold))
                .foregroundStyle(.orange)
            if let risk = meta.risk {
                Text(risk)
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
            }
            if !meta.deferredTasks.isEmpty {
                Text("Deferred: \(meta.deferredTasks.joined(separator: ", "))")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
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
