import AppKit
import SwiftUI
import CoreText

/// App-private registration; never installs a font in the user's font library.
@MainActor enum BrandTypography {
    static func register() {
        if let url = Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard NSFont(name: "JetBrainsMono-Regular", size: size) != nil else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom("JetBrainsMono-Regular", size: size).weight(weight)
    }
}
