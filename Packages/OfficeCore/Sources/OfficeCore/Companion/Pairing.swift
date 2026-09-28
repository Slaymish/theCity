import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// What the Mac's pairing QR code carries. The link key is the one secret the two devices share: it signs every command
/// and is the pre-shared key for the local network connection. Pairing again makes a new key, which unpairs every phone.
public struct PairingCode: Sendable, Equatable {
    public static let scheme = "thecity"
    public static let keyLength = 32

    /// Stable for this Mac, so the phone can tell two cities apart.
    public var hostID: UUID
    public var host: String
    public var key: Data

    public init(hostID: UUID, host: String, key: Data) {
        self.hostID = hostID
        self.host = host
        self.key = key
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "id", value: hostID.uuidString),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "key", value: Self.base64URL(key)),
        ]
        return parts.url!
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == "pair" else { return nil }
        let items = Dictionary((parts.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }
        guard let id = items["id"].flatMap(UUID.init(uuidString:)), let host = items["host"], !host.isEmpty,
              let key = items["key"].flatMap(Self.data(base64URL:)), key.count == Self.keyLength else { return nil }
        self.init(hostID: id, host: host, key: key)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

#if canImport(CryptoKit)
/// HMAC-SHA256 over the command's bytes with the link key.
public struct LinkSigner: CommandSigner {
    private let key: SymmetricKey

    public init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func tag(for payload: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    public func isValid(_ tag: Data, for payload: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: payload, using: key)
    }
}
#endif
