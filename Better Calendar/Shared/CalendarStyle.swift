import SwiftUI

extension CalendarColorName {
    var color: Color {
        switch self {
        case .betterBlue: Color(red: 0.31, green: 0.49, blue: 1.0)
        case .success: Color(red: 0.18, green: 0.66, blue: 0.42)
        case .warning: Color(red: 0.90, green: 0.54, blue: 0.18)
        case .destructive: Color(red: 0.85, green: 0.30, blue: 0.30)
        case .navy: Color(red: 0.09, green: 0.14, blue: 0.24)
        case .gray: Color(red: 0.36, green: 0.40, blue: 0.47)
        }
    }
}
