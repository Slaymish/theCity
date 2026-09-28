import SwiftUI
import VisionKit

/// First run: scan the code in The City's Settings › iPhone on your Mac. The Camera app works too, through the link it holds.
struct PairingView: View {
    let link: CityLink
    @State private var scanning = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "building.2.fill").font(.system(size: 56)).foregroundStyle(Color(Palette.primaryFill))
            VStack(spacing: 8) {
                Text("The City").font(Typography.ui(34, weight: 700)).foregroundStyle(Color(Palette.text))
                Text("Follow your agents from anywhere in the house.").foregroundStyle(Color(Palette.muted))
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("On your Mac, open The City › Settings › iPhone.", systemImage: "1.circle.fill")
                Label("Turn it on and scan the code shown there.", systemImage: "2.circle.fill")
            }
            .foregroundStyle(Color(Palette.text))
            .padding()
            .glassEffect(in: RoundedRectangle(cornerRadius: 20))
            Spacer()
            Button {
                scanning = true
            } label: {
                Label("Scan Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!DataScannerViewController.isSupported)
        }
        .padding()
        .background(Color(Palette.background))
        .sheet(isPresented: $scanning) {
            CodeScanner { text in
                scanning = false
                if let url = URL(string: text), link.pair(with: url) { return }
                failed = true
            }
            .ignoresSafeArea()
        }
        .alert("That isn’t a pairing code", isPresented: $failed) {
            Button("OK") {}
        } message: {
            Text("Scan the code in Settings › iPhone in The City on your Mac.")
        }
    }
}

/// VisionKit's live scanner, set to QR codes, handing back the first one it reads.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // Scanning can only start once the scanner is on screen.
        Task { @MainActor in try? scanner.startScanning() }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                return found(text)
            }
        }
    }
}
