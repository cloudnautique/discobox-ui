import SwiftUI

extension ToolbarContent {
    /// Keep the native toolbar and its fixed item positions without Tahoe's
    /// automatic glass capsules around the title and workspace actions.
    @ToolbarContentBuilder func studioPlainBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
