import AppKit
import OfficeCore
import SwiftUI

struct WorkspaceSnapshot: Equatable, Sendable {
    struct Document: Equatable, Identifiable, Sendable {
        var url: URL
        var modified: Date?
        var id: String { url.path }
    }
    var available = true
    var branch: String?
    var head: String?
    var changes: String?
    var documents: [Document] = []
    var brief = ""

    static func read(at directory: URL) async -> WorkspaceSnapshot {
        async let branch = Git.currentBranch(in: directory)
        async let head = Git.revision(in: directory)
        async let changes = Git.workspaceStatus(in: directory)
        var snapshot = await Task.detached(priority: .utility) {
            var result = WorkspaceSnapshot()
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
                result.available = false
                return result
            }
            let extensions: Set<String> = ["md", "txt", "pdf", "docx", "pptx", "xlsx", "csv", "png", "jpg", "html"]
            result.documents = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(200).compactMap { url in
                guard extensions.contains(url.pathExtension.lowercased()), let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                if url.lastPathComponent.lowercased().hasPrefix("readme"), (values.fileSize ?? Int.max) <= 128_000 {
                    result.brief = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(4000)) } ?? ""
                }
                return Document(url: url, modified: values.contentModificationDate)
            }
            return result
        }.value
        snapshot.branch = await branch
        snapshot.head = await head
        snapshot.changes = await changes
        return snapshot
    }

    var changedFiles: Int { changes?.split(separator: "\n").count ?? 0 }
}

struct ProjectNoticeboard: View {
    let city: CityStore
    let building: CityStore.Building
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: WorkspaceSnapshot?
    @State private var preview = ""
    @State private var purpose = ""
    @State private var openedDocument: WorkspaceSnapshot.Document?
    @State private var documentText = ""
    @State private var opening: UUID?
    @State private var readinessMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("\(building.title ?? building.name) · Noticeboard", systemImage: "rectangle.3.group.bubble")
                    .font(Typography.titleSmall)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("The brief").font(Typography.bodyMedium)
                    TextField("What is this building for? Research, a product, a campaign…", text: $purpose, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Current site or app URL (https://…)", text: $preview).textFieldStyle(.roundedBorder)
                        Button("Save brief & link") { city.describeBuilding(building.id, purpose: purpose, previewURL: preview) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .disabled(!preview.isEmpty && Self.webURL(preview) == nil)
                    }
                    if !preview.isEmpty && Self.webURL(preview) == nil { Text("Use a full http:// or https:// address.").font(Typography.caption).foregroundStyle(Color(Palette.error)) }
                    if let url = Self.webURL(preview) {
                        Link("Visit the current site or app", destination: url).font(Typography.control)
                    }
                    if let snapshot {
                        Label(snapshot.available ? "Workspace is accessible" : "Workspace is unavailable", systemImage: snapshot.available ? "folder" : "exclamationmark.triangle")
                        if let branch = snapshot.branch ?? snapshot.head {
                            Text("\(branch) · \(snapshot.changedFiles) changed file\(snapshot.changedFiles == 1 ? "" : "s")")
                                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                        }
                        if !snapshot.brief.isEmpty {
                            Text(snapshot.brief).font(Typography.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).glass(padding: 12)
                        }
                        Text("Document shelf").font(Typography.bodyMedium)
                        if snapshot.documents.isEmpty { Text("Add documents, reports or a README to this folder to put them on the shelf.").font(Typography.caption) }
                        ForEach(snapshot.documents) { doc in
                            HStack {
                                Button(doc.url.lastPathComponent, systemImage: "doc") { open(doc) }
                                    .buttonStyle(PillButtonStyle(kind: .secondary))
                                Spacer()
                                if let modified = doc.modified { Text(modified, style: .date).font(Typography.caption).foregroundStyle(Color(Palette.muted)) }
                            }
                        }
                    } else { ProgressView("Reading the noticeboard…") }
                    Text("Recent deliveries").font(Typography.bodyMedium)
                    let jobs = city.journal.filter { $0.buildingID == building.id }.suffix(10).reversed()
                    if jobs.isEmpty { Text("Finished work will be pinned here.").font(Typography.caption) }
                    ForEach(Array(jobs)) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.request).font(Typography.bodyMedium).lineLimit(3).textSelection(.enabled)
                            Text("\(job.outcome.capitalized) · \(job.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                            ForEach(job.files, id: \.self) { file in
                                Button(URL(fileURLWithPath: file).lastPathComponent, systemImage: "doc") {
                                    let directory = URL(fileURLWithPath: job.workingDirectory)
                                    let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : directory.appendingPathComponent(file)
                                    NSWorkspace.shared.open(url)
                                }.buttonStyle(.plain)
                            }
                            if let floorID = job.floorID, let floor = city.floor(floorID, in: building.id) {
                                HStack {
                                    Button("Run again") { run(job, on: floor, continuing: false) }
                                    if floor.sessionID == job.sessionID, city.canContinue(floor) {
                                        Button("Continue") { run(job, on: floor, continuing: true) }
                                    }
                                }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(opening != nil)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).glass(padding: 12)
                    }
                    if let readinessMessage { Text(readinessMessage).font(Typography.caption) }
                    OpenInMenu(directory: building.url)
                }
            }.sheltersScroll()
        }
        .padding(24).frame(width: 720, height: 680)
        .foregroundStyle(Color(Palette.text))
        .task(id: building.path) { snapshot = await WorkspaceSnapshot.read(at: building.url) }
        .onAppear { purpose = building.purpose ?? ""; preview = building.previewURL ?? "" }
        .sheet(item: $openedDocument) { doc in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(doc.url.lastPathComponent).font(Typography.titleSmall); Spacer(); Button("Done") { openedDocument = nil } }
                ScrollView { Text(documentText).font(Typography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Open document") { NSWorkspace.shared.open(doc.url) }
            }.padding(24).frame(width: 640, height: 560)
        }
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    private func open(_ document: WorkspaceSnapshot.Document) {
        guard ["md", "txt"].contains(document.url.pathExtension.lowercased()) else { NSWorkspace.shared.open(document.url); return }
        Task {
            let text = await Task.detached(priority: .utility) {
                guard let size = try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256_000 else { return "Open this document in its app to read the full text." }
                return (try? String(contentsOf: document.url, encoding: .utf8)) ?? "Unable to read this document."
            }.value
            documentText = text
            openedDocument = document
        }
    }

    private func run(_ job: JobRecord, on floor: CityStore.Floor, continuing: Bool) {
        guard let session = city.session(for: floor.id, in: building.id) else { return }
        opening = floor.id
        Task {
            let readiness = await session.settledReadiness()
            opening = nil
            guard readiness == .ready else { readinessMessage = "Open the floor to check Claude Code before sending work."; return }
            city.send(continuing ? "Continue this work: \(job.request)" : job.request, toFloor: floor.id, in: building.id, continuing: continuing)
            dismiss()
        }
    }
}
