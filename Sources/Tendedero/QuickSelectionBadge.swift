import SwiftUI

struct QuickSelectionBadge: View {
    let number: Int?
    var settled = true
    var body: some View {
        if let number {
            Text(String(number)).font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary).frame(width: 20, height: 20)
                .background(CardSurface.regular(settled: settled), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .padding(5).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
