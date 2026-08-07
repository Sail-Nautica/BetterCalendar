import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct AppRootView: View {
    @State private var store = BetterCalendarStore()
    @State private var selectedTab: BetterCalendarTab = .calendar
    @State private var calendarViewMode: CalendarViewMode = .day
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            CalendarScreen(store: store, viewMode: $calendarViewMode)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(BetterCalendarTab.calendar)

            AgendaScreen(store: store)
                .tabItem {
                    Label("Agenda", systemImage: "list.bullet.rectangle")
                }
                .tag(BetterCalendarTab.agenda)

            SearchScreen(store: store)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(BetterCalendarTab.search)
        }
        .overlay(alignment: .bottom) {
            if let undoAction = store.undoAction {
                UndoBanner(undoAction: undoAction) {
                    undoAction.perform()
                    store.clearUndo()
                } dismiss: {
                    store.clearUndo()
                }
                .padding(.bottom, 52)
            }
        }
        .alert("Local Data Error", isPresented: Binding(get: { store.lastError != nil }, set: { isPresented in
            if !isPresented {
                store.clearLastError()
            }
        })) {
            Button("OK") {
                store.clearLastError()
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.refreshForSystemTimeChange()
            }
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            store.refreshForSystemTimeChange()
        }
#endif
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
            store.refreshForSystemTimeChange()
        }
    }
}

enum BetterCalendarTab: Hashable {
    case calendar
    case agenda
    case search
}

private struct UndoBanner: View {
    let undoAction: UndoAction
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(undoAction.message)
                .font(.callout)
                .lineLimit(2)

            Spacer()

            Button(undoAction.actionTitle, action: undo)
                .font(.callout.weight(.semibold))

            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Dismiss Undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .shadow(radius: 12, y: 4)
    }
}

#Preview {
    AppRootView()
}
