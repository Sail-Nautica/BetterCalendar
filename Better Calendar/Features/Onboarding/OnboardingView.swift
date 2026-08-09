import SwiftUI

/// First-launch, local-only messaging (spec 1.1). Must not imply that local events are backed
/// up — Better Calendar has no account, cloud, or sync yet, and notification permission is
/// requested only when the user turns on their first reminder, never from here.
struct OnboardingView: View {
    let store: BetterCalendarStore
    let onFinished: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "calendar",
            title: "Welcome to Better Calendar",
            message: "A fast, focused calendar for your classes, work, and personal life."
        ),
        OnboardingPage(
            systemImage: "iphone",
            title: "Your Events Live on This Device",
            message: "Everything you create is stored only on this iPhone. Google, Apple Calendar, and cloud sync are coming in a later update — until then, nothing here is backed up automatically."
        ),
        OnboardingPage(
            systemImage: "bell",
            title: "Reminders, When You Want Them",
            message: "Better Calendar only asks for notification permission the first time you turn on a reminder for an event."
        )
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(currentPage == pages.count - 1 ? "Get Started" : "Next") {
                if currentPage == pages.count - 1 {
                    completeOnboarding()
                } else {
                    currentPage += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private func completeOnboarding() {
        store.updateSettings { $0.hasCompletedOnboarding = true }
        onFinished()
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: page.systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text(page.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }
}
