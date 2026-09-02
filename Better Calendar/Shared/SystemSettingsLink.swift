import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Spec 3.4/3A.7: the deep link offered on the states Settings can actually resolve, and on no
/// others. The URL differs per platform, so the destination lives here rather than in a view.
enum SystemSettingsLink {
    /// Where the user can change this app's calendar permission.
    ///
    /// `nil` means no such destination exists on this platform, in which case the calling
    /// surface omits the action entirely rather than offering one that does nothing.
    static var calendarPrivacy: URL? {
#if canImport(UIKit)
        // iOS deep-links to the app's own Settings page, which is where calendar access lives.
        URL(string: UIApplication.openSettingsURLString)
#elseif canImport(AppKit)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
#else
        nil
#endif
    }
}
