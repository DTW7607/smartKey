import Foundation

enum DisplayPlacement {
    struct Display {
        let id: UInt32
        let builtIn: Bool
        let active: Bool
    }

    static func preferredID(_ displays: [Display], mainID: UInt32) -> UInt32? {
        let available = displays.filter(\.active)
        return available.first(where: \.builtIn)?.id
            ?? available.first(where: { $0.id == mainID })?.id
            ?? available.first?.id
    }
}
