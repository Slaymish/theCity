import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one place to type to Claude: says who it's addressed to, grows for long prompts, and tags files with @.
struct PromptEditor<Actions: View>: View {
    let address: [String]
    let placeholder: String
    let directory: URL?
    @Binding var text: String
    var canSend = true
    let send: () -> Void
    @ViewBuilder var actions: (_ withImages: @escaping (@escaping () -> Void) -> () -> Void) -> Actions

    @State private var expanded = false
    @State private var selection = 0
    @State private var files: [String] = []
    @State private var images: [URL] = []
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool
    @Environment(\.rendersOffscreen) private var rendersOffscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(address.joined(separator: " › "))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sending to \(address.joined(separator: ", "))")
                Spacer()
                Button {
                    expanded.toggle()
                    focused = true
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Shrink the editor" : "Expand the editor for a long prompt")
                .accessibilityLabel(expanded ? "Shrink the editor" : "Expand the editor")
            }
            .font(Typography.caption)
            .foregroundStyle(Color(Palette.muted))

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.self) { url in
                            Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(Palette.hairline), lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.removeAll { $0 == url } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Color(Palette.text))
                                            .padding(3)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove this image")
                                    .accessibilityLabel("Remove image")
                                }
                        }
                    }
                }
            }

            if rendersOffscreen {
                // ImageRenderer can't draw a TextField, so offscreen renders show its text instead.
                Text(text.isEmpty ? placeholder : text)
                    .font(Typography.body)
                    .foregroundStyle(Color(text.isEmpty ? Palette.muted : Palette.text))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Palette.hairline), lineWidth: 1))
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .lineLimit(expanded ? 14...30 : 2...8)
                    // macOS ignores a changed lineLimit on a live vertical TextField, so rebuild it on toggle.
                    .id(expanded)
                    .focused($focused)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Palette.hairline), lineWidth: 1))
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) { accept() }
                    .onKeyPress(.escape) { mention == nil ? .ignored : dismissMention() }
                    .onKeyPress(.return, phases: .down) { press in
                        if !matches.isEmpty { return accept() }
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            text += "\n"
                            return .handled
                        }
                        submit()
                        return .handled
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                        images += pictures
                        let others = urls.filter { !pictures.contains($0) }
                        if !others.isEmpty { text += others.map { " @" + relative($0) }.joined() + " " }
                        return true
                    }
                    .onChange(of: text) { selection = 0 }
            }

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                        Button { complete(path) } label: {
                            Label(path, systemImage: path.hasSuffix("/") ? "folder" : "doc")
                                .font(Typography.code)
                                .foregroundStyle(Color(index == selection ? Palette.primaryText : Palette.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(index == selection ? Palette.primaryFill : .clear)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("↩ send · ⇧↩ new line · @ tag a file · ⌘V or drop images")
                    .font(Typography.caption)
                    .foregroundStyle(Color(Palette.muted))
                Spacer()
                actions(withImages)
            }
        }
        .task(id: directory) { files = await FileIndex.paths(in: directory) }
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v", attachPastedImage() else { return event }
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    private func submit() {
        if canSend { withImages(send)() }
    }

    private func withImages(_ action: @escaping () -> Void) -> () -> Void {
        {
            if !images.isEmpty {
                text += images.map { " @" + $0.path }.joined()
                images = []
            }
            action()
        }
    }

    private func attachPastedImage() -> Bool {
        let board = NSPasteboard.general
        guard board.string(forType: .string) == nil, let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TheCity-Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: url)) != nil else { return false }
        images.append(url)
        return true
    }

    private var mention: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let query = text[text.index(after: at)...]
        return query.contains(where: \.isWhitespace) ? nil : String(query)
    }

    private var matches: [String] {
        guard let query = mention?.lowercased() else { return [] }
        let hits = query.isEmpty ? files : files.filter { $0.lowercased().contains(query) }
        return Array(hits.sorted { ($0.lowercased().hasPrefix(query) ? 0 : 1, $0.count) < ($1.lowercased().hasPrefix(query) ? 0 : 1, $1.count) }.prefix(8))
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        selection = (selection + step + matches.count) % matches.count
        return .handled
    }

    private func accept() -> KeyPress.Result {
        guard matches.indices.contains(selection) else { return .ignored }
        complete(matches[selection])
        return .handled
    }

    private func complete(_ path: String) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[...at]) + path + (path.hasSuffix("/") ? "" : " ")
        focused = true
    }

    private func dismissMention() -> KeyPress.Result {
        text += " "
        return .handled
    }

    private func relative(_ url: URL) -> String {
        guard let directory, url.path.hasPrefix(directory.path + "/") else { return url.path }
        return String(url.path.dropFirst(directory.path.count + 1))
    }
}

/// Relative paths in a working directory for @ completion, skipping hidden and generated folders.
enum FileIndex {
    private static let skipped: Set<String> = ["node_modules", "build", "dist", "DerivedData", ".build", "Pods"]

    static func paths(in directory: URL?) async -> [String] {
        guard let directory else { return [] }
        return await Task.detached(priority: .utility) {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var paths: [String] = []
            let base = directory.path.count + 1
            while let url = walker.nextObject() as? URL, paths.count < 5000 {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isFolder, skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                paths.append(String(url.path.dropFirst(base)) + (isFolder ? "/" : ""))
            }
            return paths
        }.value
    }
}

extension EnvironmentValues {
    @Entry var rendersOffscreen = false
}
