import SwiftUI

struct LineView: View {
    @ObservedObject var line: Line
    private let texts: TextHistory
    private let links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    private static let controlsIDs: [Shelf: UUID] = [.images: UUID(), .texts: UUID(), .links: UUID()]
    private static let headerIDs: [Shelf: UUID] = [.images: UUID(), .texts: UUID(), .links: UUID()]
    static let searchSummaryID = UUID()
    static let searchPanelID = UUID()
    private static let noticeID = UUID()
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 0) {
                ForEach(line.presentation.shelves, id: \.self) { shelf in
                    ZStack(alignment: .topLeading) {
                        ShelfBackdrop().frame(width: width, height: Layout.panelHeight)
                        Rope(width: width)
                        if shelf == .texts { TextShelfView(line: line, texts: texts, width: width) }
                        else if shelf == .links { LinkShelfView(line: line, links: links, width: width) }
                        else {
                            if line.displayItems.isEmpty {
                                Text(line.shelfSearch?.isActive(for: .image) == true || line.favoritesOnly ? L("No matching items") : L("Take a screenshot and it will hang here")).font(.system(size: 12))
                                    .padding(9).background(.regularMaterial, in: Capsule()).position(x: width / 2, y: 95)
                            }
                            let displayed = line.displayItems
                            let quickNumbers = line.activeShelf == .images && line.searchEditingShelf == nil
                                ? Dictionary(uniqueKeysWithValues: line.quickSelectionIDs.enumerated().map { ($0.element, $0.offset + 1) }) : [:]
                            let range = Layout.visibleRange(count: displayed.count, width: width, offset: line.scrollOffset)
                            ForEach(range.map { (index: $0, item: displayed[$0]) }, id: \.item.id) { index, item in
                                let x = Layout.x(index: index, scrollOffset: line.scrollOffset)
                                let ropeY = Layout.ropeY(x: x, width: width)
                                PeggedView(item: item, line: line, quickNumber: quickNumbers[item.id])
                                    .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                                    .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                            }
                        }
                        HStack(spacing: 7) {
                            Button { line.focusShelf(shelf) } label: {
                                Label(shelf.title, systemImage: shelf.icon)
                            }.padding(.horizontal, 7).padding(.vertical, 2)
                                .background(line.activeShelf == shelf ? line.theme.accent(shelf) : Color.black.opacity(0.72), in: Capsule())
                                .help(L("Tab switches the active shelf"))
                                .background(hitRect(Self.headerIDs[shelf]!))
                            Spacer()
                            if line.activeShelf == shelf { ShelfControls(line: line).background(hitRect(Self.controlsIDs[shelf]!)) }
                        }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white).buttonStyle(.plain).controlSize(.mini)
                            .padding(.horizontal, 14).padding(.top, 3)
                    }.frame(width: width, height: Layout.panelHeight).clipped()
                }
            }.frame(width: width, height: line.panelHeight, alignment: .topLeading)
                .overlay(alignment: .top) {
                    if width >= 700, line.isShelfSearchActive, line.searchEditingShelf == nil {
                        ShelfSearchSummary(line: line, shelf: line.activeShelf)
                            .frame(maxWidth: min(360, width - 380))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(hitRect(Self.searchSummaryID))
                            .padding(.top, 4)
                    }
                }
                .overlay(alignment: .center) {
                    if let shelf = line.searchEditingShelf,
                       line.isShelfSearchActive {
                        ShelfSearchBar(line: line, shelf: shelf).id(shelf)
                            .frame(width: max(0, min(560, width - 32)))
                            .background(hitRect(Self.searchPanelID))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ShelfNotice(line: line)
                        .background(hitRect(Self.noticeID))
                }
                .onAppear { line.setViewportWidth(width) }
                .onChange(of: width) { _, value in line.setViewportWidth(value) }
        }
        .onPreferenceChange(HitRectsKey.self) { line.hitRects = $0; line.shelfHitGeometryUpdateCount += 1 }
    }
    private func hitRect(_ id: UUID) -> some View {
        GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [id: g.frame(in: .global)]) }
    }
}

/// High-frequency row scrolling must not invalidate the other two rows just
/// to update a selection count or a notice. Observe their models at the small
/// controls that actually depend on them.
private struct ShelfControls: View {
    @ObservedObject var line: Line
    @ObservedObject private var texts: TextHistory
    @ObservedObject private var links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    var body: some View {
        HStack(spacing: 7) {
            if line.activeSelectionCount > 1 {
                Text(String(format: L("%d selected"), line.activeSelectionCount)).monospacedDigit()
                iconButton("doc.on.doc", L("Copy")) { line.copySelection() }
                iconButton("trash", L("Move to Trash…")) { line.onTrashRequested?() }
            }
            Button { line.onCommandsRequested?() } label: {
                Label(L("Actions"), systemImage: "command").frame(minHeight: 18)
            }.help(L("Actions") + " · " + line.keyboardBindings.title(.commandPalette))
                .accessibilityLabel(L("Actions")).accessibilityIdentifier("shelf-actions")
            iconButton("magnifyingglass", L("Search shelves")) { line.beginShelfSearch() }.disabled(line.shelfSearch == nil)
            iconButton("arrow.left.arrow.right", L("Switch shelf")) { line.switchShelf() }
            iconButton("rectangle.split.2x1", L("Both shelves")) { line.toggleBothShelves() }
            iconButton("square.grid.2x2", L("Library…")) { line.onLibraryRequested?() }
            Menu {
                Toggle(L("Favorites"), isOn: Binding(get: { line.activeFavoritesOnly }, set: { line.setActiveFavorites($0) }))
                Button(L("Export copies…")) { line.onExportRequested?() }.disabled(line.activeSelectionCount == 0)
                Button(L("Move to Trash…")) { line.onTrashRequested?() }.disabled(line.activeSelectionCount == 0)
                Divider()
                Button(L("Settings…")) { line.onSettingsRequested?() }
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 24, minHeight: 18).foregroundStyle(.white) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Shelf settings"))
        }.padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.72), in: Capsule())
    }
    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(minWidth: 24, minHeight: 18) }
            .accessibilityLabel(title).help(title)
    }
}

private struct ShelfNotice: View {
    @ObservedObject var line: Line
    @ObservedObject private var texts: TextHistory
    @ObservedObject private var links: LinkHistory
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }
    var body: some View {
        if let message = (line.activeShelf == .texts ? (texts.notice ?? line.notice) : line.activeShelf == .links ? (links.notice ?? line.notice) : line.notice) {
            HStack { Text(message); Button(L("Dismiss")) { line.notice = nil; texts.notice = nil; links.notice = nil } }
                .font(.system(size: 11)).padding(7).background(.regularMaterial, in: Capsule())
        }
    }
}

/// A smoked glass band behind each shelf row, so the cards stand out from a
/// busy desktop instead of blending into it. It is only a picture: it reports
/// no hit rectangle, so the panel keeps ignoring the pointer over it and a
/// click there reaches the app or the desktop underneath, exactly as it does
/// between cards. A plain tint, not a live blur: it costs nothing to slide
/// down with the line and nothing while it rests over moving content.
struct ShelfBackdrop: View {
    static let cornerRadius: CGFloat = 18
    static let topTint = 0.40, bottomTint = 0.30
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        shape.fill(LinearGradient(colors: [Color.black.opacity(Self.topTint), Color.black.opacity(Self.bottomTint)],
                                  startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct Rope: View {
    let width: CGFloat
    private var path: Path {
        Path { p in
            p.move(to: CGPoint(x: -20, y: Layout.ropeTop))
            p.addQuadCurve(to: CGPoint(x: width + 20, y: Layout.ropeTop),
                control: CGPoint(x: width / 2, y: Layout.ropeTop + 2 * Layout.sag(width: width)))
        }
    }
    /// The line fades out at both ends. Shading each stroke with the fade
    /// draws it directly; a mask and a blur over the full screen width made
    /// every row an offscreen pass on each frame the line slid or swayed.
    private func faded(_ color: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.08),
            .init(color: color, location: 0.92), .init(color: color.opacity(0), location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }
    var body: some View {
        ZStack {
            // Two soft strokes stand in for the blurred shadow.
            path.stroke(faded(Color.black.opacity(0.09)), lineWidth: 3.4).offset(y: 1.2)
            path.stroke(faded(Color.black.opacity(0.16)), lineWidth: 1.9).offset(y: 1.2)
            path.stroke(faded(Color(white: 0.55)), lineWidth: 1.2)
            path.stroke(faded(Color.white.opacity(0.45)), lineWidth: 0.4).offset(y: -0.35)
        }.allowsHitTesting(false)
    }
}
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}
