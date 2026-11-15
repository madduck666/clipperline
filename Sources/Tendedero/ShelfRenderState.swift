import SwiftUI

/// A row's visual dependency on Line. Actions keep the live Line reference,
/// while unrelated row scrolling/animation cannot invalidate every card.
struct ShelfRenderState: Equatable {
    let theme: ShelfTheme
    let scale: CGFloat
    let searchActive: Bool
    let pinnedHint: String
    let quickIDs: [UUID]
    let draggingID: UUID?
    let settled: Bool

    @MainActor init(line: Line, shelf: Shelf) {
        theme = line.theme
        scale = Layout.scale
        searchActive = line.shelfSearch?.isActive(for: shelf.libraryKind) == true
        pinnedHint = line.keyboardBindings.title(.pinnedOnly)
        quickIDs = line.activeShelf == shelf && line.searchEditingShelf == nil ? line.quickSelectionIDs : []
        draggingID = shelf == .texts ? line.draggingID : nil
        settled = line.shelfSettled
    }
}

/// Thumbnail and metadata requests depend only on the bounded visible payload,
/// never an equality pass over the entire link history on every frame.
struct VisibleLinkPayload: Equatable {
    let id: UUID
    let thumbnailPath: String?
}
