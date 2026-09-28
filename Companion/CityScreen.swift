import OfficeCore
import RealityKit
import SwiftUI

/// The whole app once paired: one building at a time, with a glass banner along the bottom that names the project.
/// Swiping the banner flies to the next building; tapping a storey goes into that floor.
struct CityScreen: View {
    let link: CityLink
    @State private var city = PhoneCity()
    @State private var selection: UUID?
    @State private var asking = false
    @State private var composing = false
    @State private var confirmingStop = false
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark && BrandStore.shared.current.supportsDark }
    private var buildings: [BuildingSnapshot] { link.snapshot?.buildings ?? [] }

    var body: some View {
        ZStack(alignment: .bottom) {
            scene
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let floor = city.floor, let building = city.building {
                    FloorBanner(building: building, floor: floor, busy: !link.outstanding.isEmpty,
                                back: { city.leaveFloor() }, answer: { asking = true }, stop: { confirmingStop = true })
                        .padding()
                } else if !buildings.isEmpty {
                    pager
                }
            }
            if link.snapshot == nil { waiting }
        }
        .background(Color(DayCycle.now.sky(dark: dark)))
        .onChange(of: link.snapshot, initial: true) {
            guard let snapshot = link.snapshot else { return }
            city.dark = dark
            city.update(from: snapshot)
            if selection == nil || !buildings.contains(where: { $0.id == selection }) { selection = city.buildingID }
        }
        .onChange(of: selection) {
            guard let id = selection, id != city.buildingID else { return }
            Task { await city.fly(to: id) }
        }
        .sheet(isPresented: $asking) {
            if let building = city.building {
                QuestionsSheet(link: link, building: building, onlyFloor: city.floorID)
            }
        }
        .sheet(isPresented: $composing) {
            if let building = city.building { NewJobSheet(link: link, building: building) }
        }
        .confirmationDialog("Stop this job?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Job", role: .destructive) {
                if let id = city.floorID { link.send(.cancel(floor: id)) }
            }
        } message: {
            Text("The team stops where it is. Anything already written stays.")
        }
        .alert("Your Mac said no", isPresented: Binding(get: { link.notice != nil }, set: { if !$0 { link.notice = nil } })) {
            Button("OK") { link.notice = nil }
        } message: {
            Text(link.notice ?? "")
        }
    }

    private var scene: some View {
        GeometryReader { geometry in
            RealityView { content in
                content.camera = .virtual
                content.add(city.tower.root)
                city.tower.updates = content.subscribe(to: SceneEvents.Update.self) { [city] event in city.tower.update(event.deltaTime) }
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in city.tapped(value.entity) })
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                city.tower.camera.orbit(dx: Float(delta.width), dy: Float(delta.height))
            }.onEnded { _ in lastDrag = .zero })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                city.tower.camera.zoom(by: Float(lastMagnification / value.magnification))
                lastMagnification = value.magnification
            }.onEnded { _ in lastMagnification = 1 })
            .onAppear { city.tower.fit(geometry.size) }
            .onChange(of: geometry.size) { city.tower.fit(geometry.size) }
        }
        .ignoresSafeArea()
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(buildings) { building in
                    BuildingBanner(building: building, index: buildings.firstIndex(of: building) ?? 0, count: buildings.count,
                                   answer: { asking = true }, compose: { composing = true })
                        .padding()
                        .containerRelativeFrame(.horizontal)
                        .id(building.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var topBar: some View {
        HStack {
            ConnectionPill(link: link)
            Spacer()
            Menu {
                if let host = link.pairing?.host { Text("Paired with \(host)") }
                Button("Unpair", role: .destructive) { link.unpair() }
            } label: {
                Image(systemName: "ellipsis").padding().glassEffect(in: Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking for \(link.pairing?.host ?? "your Mac")…").foregroundStyle(Color(Palette.muted))
            Text("Open The City on your Mac, on the same Wi-Fi.").font(.footnote).foregroundStyle(Color(Palette.muted))
        }
        .padding()
        .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        .frame(maxHeight: .infinity)
    }
}

/// Says how the phone is hearing from the Mac, and how long ago when it isn't.
struct ConnectionPill: View {
    let link: CityLink

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color(link.route == .none ? Palette.muted : Palette.text))
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .glassEffect(in: Capsule())
    }

    private var symbol: String {
        switch link.route {
        case .local: "wifi"
        case .cloud: "icloud"
        case .none: "moon.zzz"
        }
    }

    private var text: String {
        let host = link.snapshot?.host ?? link.pairing?.host ?? "Mac"
        switch link.route {
        case .local: return host
        case .cloud where !link.isStale: return "\(host) via iCloud"
        default:
            guard let seen = link.snapshot?.takenAt else { return "Not connected" }
            return "Last heard \(seen.formatted(date: .omitted, time: .shortened))"
        }
    }
}

struct BuildingBanner: View {
    let building: BuildingSnapshot
    let index: Int
    let count: Int
    let answer: () -> Void
    let compose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(building.displayName).font(Typography.ui(22, weight: 600)).foregroundStyle(Color(Palette.text)).lineLimit(1)
                    Text(status).font(.subheadline).foregroundStyle(Color(building.waitingCount > 0 ? Palette.manager : Palette.muted))
                }
                Spacer()
                if count > 1 {
                    Text("\(index + 1) of \(count)").font(.caption.monospacedDigit()).foregroundStyle(Color(Palette.muted))
                }
            }
            HStack {
                if building.waitingCount > 0 {
                    Button(action: answer) {
                        Label(building.waitingCount == 1 ? "Answer" : "Answer \(building.waitingCount)", systemImage: "hand.raised.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color(Palette.manager))
                }
                Button(action: compose) { Label("New Job", systemImage: "plus") }
                    .buttonStyle(.glass)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    /// The same wording as the Mac's menu bar.
    private var status: String {
        let floors = building.floors.isEmpty ? "Empty lot" : "\(building.floors.count) floor\(building.floors.count == 1 ? "" : "s")"
        return building.waitingCount > 0 ? "Needs you" : building.workingCount > 0 ? "\(building.workingCount) working"
            : building.floors.isEmpty ? floors : "\(floors) · all quiet"
    }
}

struct FloorBanner: View {
    let building: BuildingSnapshot
    let floor: FloorSnapshot
    let busy: Bool
    let back: () -> Void
    let answer: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Back to \(building.displayName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(floor.name).font(Typography.ui(20, weight: 600)).foregroundStyle(Color(Palette.text)).lineLimit(1)
                    Text(building.displayName).font(.caption).foregroundStyle(Color(Palette.muted))
                }
                Spacer()
                if busy { ProgressView() }
            }
            if let request = floor.request {
                Text(request).font(.subheadline).foregroundStyle(Color(Palette.text)).lineLimit(3)
            }
            if let line = activity {
                Label(line, systemImage: floor.isRunning ? "bolt.fill" : "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Color(Palette.muted)).lineLimit(2)
            }
            HStack {
                if !floor.questions.isEmpty {
                    Button(action: answer) { Label("Answer", systemImage: "hand.raised.fill") }
                        .buttonStyle(.glassProminent)
                        .tint(Color(Palette.manager))
                }
                if floor.isRunning {
                    Button(role: .destructive, action: stop) { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 24))
    }

    /// What's happening now: the step of the room most recently at work, or how the job ended.
    private var activity: String? {
        switch floor.phase {
        case .running:
            let working = floor.handoffs.filter { $0.phase == .working }
            if let handoff = working.last { return "\(handoff.room.capitalized): \(handoff.step ?? floor.captions[handoff.room] ?? "working")" }
            return floor.captions["manager"].map { "Manager: \($0)" } ?? "The manager is working"
        case .completed(let summary): return summary ?? "Done"
        case .cancelled: return "Stopped"
        case .failed(let message): return message ?? "The job stopped"
        case .idle: return nil
        }
    }
}
