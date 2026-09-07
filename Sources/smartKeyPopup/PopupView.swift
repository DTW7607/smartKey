import Combine
import SwiftUI

final class BubbleContent: ObservableObject {
    @Published var text: String
    @Published var symbol = ""
    @Published var status = ""

    init(text: String = "") {
        self.text = text
    }
}

@available(macOS 26.0, *)
struct BubbleLabel: View {
    var config: PopupConfiguration
    @ObservedObject var content: BubbleContent

    var body: some View {
        let style = config.content
        HStack(spacing: 10) {
            if !content.symbol.isEmpty { Image(systemName: content.symbol).font(.system(size: style.fontSize * 0.65)) }
            Text(content.text)
        }
            .font(.system(size: style.fontSize, weight: style.fontWeight))
            .padding(.horizontal, style.paddingHorizontal)
            .padding(.vertical, style.paddingVertical)
            .environment(\.appearsActive, config.glass.controlActiveState == .key)
            .environment(\.controlActiveState, config.glass.controlActiveState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.text + "，" + content.status)
    }
}
