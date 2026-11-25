import SwiftUI

/// Display the brand artwork or the user's custom portrait.
struct BrandMark: View {
    @ObservedObject private var store = CustomAvatarStore.shared
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = store.appearance.displayPortrait {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image("CodePaxPortrait").resizable().interpolation(.high).scaledToFit()
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: min(geometry.size.width, geometry.size.height) * 0.22))
        }.accessibilityHidden(true)
    }
}
