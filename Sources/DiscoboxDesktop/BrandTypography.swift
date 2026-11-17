import AppKit
import CoreText

/// App-private registration; never installs a font in the user's font library.
@MainActor enum BrandTypography {
    static func register() {
        if let url = Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
