import AppKit
import CoreImage.CIFilterBuiltins
import OfficeCore
import SwiftUI

/// Settings › iPhone: turns the companion link on and shows the code the phone scans to pair.
struct CompanionSettings: View {
    @Bindable var host = CompanionHost.shared

    var body: some View {
        Section {
            Toggle("Let The City on your iPhone follow and answer jobs", isOn: $host.isOn)
        } footer: {
            Text("Your phone sees every project’s floors and can answer questions, approve or deny once, start jobs through Reception and cancel them. It can’t change permissions or always-allow anything.")
                .font(.caption).foregroundStyle(Color(Palette.muted))
        }
        if host.isOn, let code = host.code {
            Section("Pair a phone") {
                HStack {
                    Spacer()
                    if let image = Self.qrImage(code.url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .accessibilityLabel("Pairing code for \(code.host)")
                    }
                    Spacer()
                }
                Text("Open The City on your iPhone and scan this code. Anyone who can see it can pair, so only show it to your own phone.")
                    .font(.caption).foregroundStyle(Color(Palette.muted))
                Button("Pair Again…") {
                    let alert = NSAlert()
                    alert.messageText = "Pair again with a new code?"
                    alert.informativeText = "Every phone paired now stops working until it scans the new code."
                    alert.addButton(withTitle: "Pair Again")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { host.pairAgain() }
                }
            }
            Section("On this network") {
                if host.phones.isEmpty {
                    Text("No phone connected").foregroundStyle(Color(Palette.muted))
                } else {
                    ForEach(host.phones, id: \.self) { Text($0) }
                }
            }
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
