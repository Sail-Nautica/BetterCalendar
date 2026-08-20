import SwiftUI

extension View {
    /// macOS sizes a sheet to its content's *ideal* size, and a `List` reports no ideal
    /// height — so a sheet built around one collapses to just its navigation bar, which is
    /// how the Calendars sheet ended up rendering as an empty strip with a Done button.
    /// Giving the content an explicit ideal frame is what makes the rows appear; on iPhone
    /// the system sizes sheets itself, so this is a no-op there.
    func macSheetFrame(minWidth: CGFloat = 480, minHeight: CGFloat = 560) -> some View {
#if canImport(UIKit)
        self
#else
        frame(
            minWidth: minWidth,
            idealWidth: minWidth,
            maxWidth: .infinity,
            minHeight: minHeight,
            idealHeight: minHeight,
            maxHeight: .infinity
        )
#endif
    }
}
