import SwiftUI

struct PhoneTrackRowSurface<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .frame(minHeight: 48)
            .background(selected ? PhoneStyle.button : hovered ? PhoneStyle.carbon : .clear)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
