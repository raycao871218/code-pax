import SwiftUI

/// Focus the in-app portrait on the face and headset; the home-screen artwork stays unchanged.
struct BrandMark: View {
    @ObservedObject private var store = CustomAvatarStore.shared
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = store.appearance.displayPortrait {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image("CodePaxPortrait").resizable().interpolation(.high).scaledToFit()
                        .scaleEffect(1.24, anchor: .top)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: min(geometry.size.width, geometry.size.height) * 0.22))
        }.accessibilityHidden(true)
    }
}
