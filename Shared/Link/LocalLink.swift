import CryptoKit
import Foundation
import Network
import OfficeCore

/// The local network link: Bonjour to find the Mac, TLS with a pre-shared key derived from the link key, and
/// length-framed JSON. Anyone on the network without the key can neither read the city nor send it anything.
enum LinkTLS {
    static let serviceType = "_thecity._tcp"

    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // A separate key from the one that signs commands, so neither use can weaken the other.
        let secret = HMAC<SHA256>.authenticationCode(for: Data("thecity-local-link".utf8), using: SymmetricKey(data: key))
        let identity = Data("thecity".utf8)
        let psk = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskIdentity = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, pskIdentity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Also works over Apple's peer-to-peer Wi-Fi, so a phone and Mac with no router between them still find each other.
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One end of a link connection, on either device.
@MainActor
final class LinkConnection {
    let connection: NWConnection
    var onMessage: ((LinkMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    private var framer = LinkFramer()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.changed(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: LinkMessage) {
        guard !closed, let data = try? LinkFramer.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready: onReady?()
        case .failed, .cancelled: close()
        case .waiting(let error):
            // A TLS failure here almost always means the two devices hold different keys; waiting won't fix it.
            if case .tls = error { close() }
        default: break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.framer.feed(data) { self.onMessage?(message) }
                    } catch {
                        return self.close()
                    }
                }
                if isComplete || error != nil { self.close() } else { self.receive() }
            }
        }
    }
}

#if os(macOS)
/// The Mac's side: advertises the city on the local network and accepts phones that hold the link key.
@MainActor
final class LinkListener {
    private var listener: NWListener?
    var onConnection: ((LinkConnection) -> Void)?

    func start(key: Data, name: String, hostID: UUID) {
        stop()
        guard let listener = try? NWListener(using: LinkTLS.parameters(key: key)) else { return }
        var txt = NWTXTRecord()
        txt["id"] = hostID.uuidString
        listener.service = NWListener.Service(name: name, type: LinkTLS.serviceType, domain: nil, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                let link = LinkConnection(connection)
                self.onConnection?(link)
                link.start()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
#endif

#if os(iOS)
/// The phone's side: looks for the paired Mac's advertisement and connects to it.
@MainActor
final class LinkBrowser {
    private var browser: NWBrowser?

    func start(hostID: UUID, key: Data, found: @escaping @MainActor (NWEndpoint) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkTLS.serviceType, domain: nil), using: LinkTLS.parameters(key: key))
        browser.browseResultsChangedHandler = { results, _ in
            let match = results.first { result in
                if case .bonjour(let txt) = result.metadata { txt["id"] == hostID.uuidString } else { false }
            }
            guard let endpoint = match?.endpoint else { return }
            Task { @MainActor in found(endpoint) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
#endif
