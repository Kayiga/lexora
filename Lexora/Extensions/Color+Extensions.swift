import SwiftUI

extension Array where Element == Double {
    /// Returns the arithmetic mean, or 0 when the array is empty.
    var average: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}

extension Color {
    static let linguaBlue = Color(red: 0.22, green: 0.49, blue: 0.98)
    static let linguaPurple = Color(red: 0.55, green: 0.35, blue: 0.95)

    // Semantic accent derived from brand palette
    static let brand = linguaBlue
}

extension View {
    // Convenience: apply a card-style background
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
