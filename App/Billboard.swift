import AppKit
import OfficeCore
import RealityKit
import SwiftUI

/// SwiftUI views turned into camera-facing planes, so signs and bubbles use the app's own type and tokens.
@MainActor
enum Billboard {
    static let pixelsPerMetre: Float = 105

    static func make<Content: View>(_ view: Content, dark: Bool, faceCamera: Bool = true) -> ModelEntity? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        let width = Float(image.width) / Float(renderer.scale) / pixelsPerMetre * 2
        let height = Float(image.height) / Float(renderer.scale) / pixelsPerMetre * 2
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        if faceCamera {
            // Walls and desks otherwise slice through labels that sit near geometry.
            material.readsDepth = false
        }
        let plane = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        if faceCamera { plane.components.set(BillboardComponent()) }
        return plane
    }
}

struct FramedJobView: View {
    let job: JobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.request)
                .font(Typography.ui(17, weight: 600))
                .foregroundStyle(Color(Palette.text))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text([job.date.formatted(.dateTime.day().month(.abbreviated)), job.costUSD.map { $0.formatted(.currency(code: "USD")) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Typography.ui(14, weight: 500))
                .foregroundStyle(Color(Palette.muted))
        }
        .padding(14)
        .frame(width: 220, height: 140)
        .background(Color(Palette.glassTop))
        .padding(8)
        .background(Color(Palette.desk))
    }
}

struct BannerView: View {
    let symbol: String
    let title: String
    let colour: NSColor

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .bold))
            Text(title)
                .font(Typography.ui(28, weight: 700))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Color(Palette.textOn(colour)))
        .padding(.top, 22)
        .padding(.bottom, 58)
        .frame(width: 200)
        .background(Pennant().fill(Color(colour)))
    }
}

/// A banner with a swallowtail hem.
struct Pennant: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch = rect.height * 0.16
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ClockFaceView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 64, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(Palette.screenOn))
            .frame(width: 240, height: 120)
            .background(Color(Palette.screenOff))
    }
}

struct BubbleView: View {
    let symbol: String
    let text: String
    let colour: NSColor
    var rooms: RoomCounts?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(Palette.textOn(colour)))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(colour)))
            Text(text)
                .font(Typography.outfit(18, weight: 600))
                .foregroundStyle(Color(Palette.text))
                .lineLimit(1)
            if let rooms {
                ForEach([RoomState.waiting, .working].filter { rooms.count($0) > 0 }, id: \.self) { state in
                    HStack(spacing: 4) {
                        Image(systemName: state.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(state.colour))
                        Text("\(rooms.count(state))")
                            .font(Typography.outfit(18, weight: 600).monospacedDigit())
                            .foregroundStyle(Color(Palette.text))
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .background(Capsule().fill(Color(Palette.glassBottom)))
        .overlay(Capsule().strokeBorder(Color(Palette.hairline), lineWidth: 1))
    }
}

/// The rooftop sign naming the project, with its folder underneath.
struct ProjectBillboardView: View {
    let title: String
    let folder: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Typography.outfit(56, weight: 800))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if title.caseInsensitiveCompare(folder) != .orderedSame {
                Label(folder, systemImage: "folder.fill")
                    .font(Typography.ui(18, weight: 600))
            }
        }
        .foregroundStyle(Color(Palette.textOn(Palette.primaryFill)))
        .padding(.horizontal, 36)
        .padding(.vertical, 22)
        .frame(minWidth: 360, maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(Palette.primaryFill)))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(Palette.walls)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(Palette.hairline), lineWidth: 2))
        .fixedSize()
    }
}
