import SwiftUI

@available(macOS 26.0, *)
struct BubbleLabel: View {
    var config: PopupConfiguration

    var body: some View {
        let content = config.content
        Text(content.text)
            .font(.system(size: content.fontSize, weight: content.fontWeight))
            .padding(.horizontal, content.paddingHorizontal)
            .padding(.vertical, content.paddingVertical)
            .environment(\.appearsActive, config.glass.controlActiveState == .key)
            .environment(\.controlActiveState, config.glass.controlActiveState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
