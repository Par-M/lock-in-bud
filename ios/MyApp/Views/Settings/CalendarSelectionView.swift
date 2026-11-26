import EventKit
import SwiftUI

struct CalendarSelectionView: View {
    @Environment(CalendarService.self) private var calendarService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppHeader(eyebrow: "CALENDAR", title: "Choose calendars.")

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "CALENDARS TO SCHEDULE")
                        AppCard(padding: 12) {
                            ForEach(calendarService.availableCalendars, id: \.calendarIdentifier) { calendar in
                                Button {
                                    calendarService.setCalendarSelected(
                                        calendar,
                                        selected: !calendarService.isSelected(calendar)
                                    )
                                } label: {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(Color(calendar.cgColor))
                                            .frame(width: 12, height: 12)
                                        Text(calendar.title)
                                            .font(DesignPalette.body(14))
                                            .foregroundStyle(DesignPalette.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        if calendarService.isSelected(calendar) {
                                            Image(systemName: "checkmark")
                                                .font(DesignPalette.body(14).weight(.bold))
                                                .foregroundStyle(DesignPalette.primary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("Only the selected calendars are used to find free time when scheduling.")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Calendars to Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    CalendarSelectionView()
        .environment(CalendarService())
}
