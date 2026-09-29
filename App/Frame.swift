import SwiftUI

/// The space the world's overlays and camera leave clear, owned by the frame so no overlay works it out itself.
struct SceneSafeArea: Equatable {
    /// Taken by the floor's side panel.
    var trailing: CGFloat = 0
    /// Taken by the dispatch rail.
    var bottom: CGFloat = 0

    init(panelOpen: Bool = false, rail: CGFloat = 0) {
        trailing = panelOpen ? OfficeView.panelWidth + 20 : 0
        bottom = rail
    }
}

extension EnvironmentValues {
    @Entry var sceneSafeArea = SceneSafeArea()
}

/// Where you are, from the city down to a desk. Every segment but the last goes back up to it.
struct Breadcrumb: View {
    struct Crumb {
        var name: String
        /// Nil for the level you're on.
        var go: (() -> Void)?
    }

    var home: (() -> Void)?
    var crumbs: [Crumb] = []
    /// The home segment shows only the brand symbol, for a row that's short of room.
    var symbolOnly = false

    /// What Esc does: the level above this one.
    var up: (() -> Void)? { crumbs.isEmpty ? nil : crumbs.dropLast().last?.go ?? home }

    var body: some View {
        if crumbs.isEmpty {
            Wordmark(compact: true)
        } else {
            trail
        }
    }

    func compact(_ on: Bool = true) -> Breadcrumb {
        var copy = self
        copy.symbolOnly = on
        return copy
    }

    private var trail: some View {
        HStack(spacing: 0) {
            Button { home?() } label: { Wordmark(compact: true, symbolOnly: symbolOnly) }
                .buttonStyle(SegmentStyle(colour: Palette.muted))
                .help("Back to the city")
            ForEach(crumbs.indices, id: \.self) { index in
                let crumb = crumbs[index]
                Image(systemName: "chevron.forward")
                    .font(Typography.controlQuiet)
                    .foregroundStyle(Color(Palette.muted))
                    .accessibilityHidden(true)
                if let go = crumb.go {
                    Button(crumb.name, action: go)
                        .buttonStyle(SegmentStyle(colour: Palette.muted))
                        .lineLimit(1)
                        .help(index == crumbs.count - 2 ? "Back to \(crumb.name) (esc)" : "Back to \(crumb.name)")
                } else {
                    Text(crumb.name)
                        .font(Typography.controlQuiet)
                        .lineLimit(1)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 15)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets()))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
    }
}

extension Breadcrumb {
    @MainActor static func here(_ city: CityStore) -> Breadcrumb {
        let toCity = { city.route = .city }
        switch city.route {
        case .welcome, .city:
            return Breadcrumb()
        case .building(let id):
            return Breadcrumb(home: toCity, crumbs: [Crumb(name: city.building(id)?.name ?? "Building")])
        case .newFloor(let id):
            return Breadcrumb(home: toCity, crumbs: [Crumb(name: city.building(id)?.name ?? "Building") { city.cancelNewFloor() },
                                                     Crumb(name: "New floor")])
        case .floor(let building, let floor):
            let session = city.sessions[floor]
            var crumbs = [Crumb(name: city.building(building)?.name ?? "Building") { city.route = .building(building) },
                          Crumb(name: session?.displayTitle ?? city.floor(floor, in: building)?.name ?? "Floor")]
            if let session, let room = session.selectedRoom {
                crumbs[1].go = { session.selectedRoom = nil }
                crumbs.append(Crumb(name: room == "manager" ? "Manager" : session.displayName(room)))
            }
            return Breadcrumb(home: toCity, crumbs: crumbs)
        }
    }
}
