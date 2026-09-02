import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct AppRootView: View {
    @State private var store: BetterCalendarStore
    @State private var selectedTab: BetterCalendarTab
    @State private var calendarViewMode: CalendarViewMode
    @State private var isShowingOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = BetterCalendarStore()
        _store = State(initialValue: store)
        // BC-VIEW-010 (spec 1.2): resume where the user left off across relaunch.
        _selectedTab = State(initialValue: store.settings.lastSelectedTab ?? .calendar)
        _calendarViewMode = State(initialValue: store.settings.defaultCalendarView)
        // BC-ONB-001 (spec 1.1): shown once, on first launch.
        _isShowingOnboarding = State(initialValue: !store.settings.hasCompletedOnboarding)
    }

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
        .task {
            // Spec 3.4/3B.3: the first authorization read and the first discovery pass happen
            // here rather than in `load()` — launch itself touches nothing from EventKit.
            store.discoverDeviceCalendars()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.refreshForSystemTimeChange()
                // Spec 3.4 (BC-EK-022): re-checked on every foreground transition, never
                // cached for the process lifetime. A user can revoke access in Settings while
                // the app is backgrounded; on return the app must degrade without crashing and
                // without losing local data. Spec 3B.0: a foreground is also one of Phase 3B's
                // explicit discovery triggers — an unchanged device costs one comparison.
                store.discoverDeviceCalendars()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            store.updateLastViewState(tab: newTab)
        }
        .onChange(of: calendarViewMode) { _, newMode in
            store.updateLastViewState(viewMode: newMode)
        }
        .onboardingCover(isPresented: $isShowingOnboarding) {
            OnboardingView(store: store) {
                isShowingOnboarding = false
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

private extension View {
    /// BC-ONB-001 is specced as a full-screen first-launch cover, but `fullScreenCover`
    /// is unavailable on macOS — there the equivalent presentation is a modal sheet.
    @ViewBuilder
    func onboardingCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
#if canImport(UIKit)
        fullScreenCover(isPresented: isPresented, content: content)
#else
        sheet(isPresented: isPresented, content: content)
#endif
    }
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
