import Foundation
import OfficeCore
import Security

/// Keeps the pairing in the Keychain on both devices: the link key, and which Mac it belongs to.
enum LinkKeychain {
    private static let service = "nz.hamish.TheCity.link"

    static func load() -> PairingRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "pairing", kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PairingRecord.self, from: data)
    }

    static func save(_ record: PairingRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "pairing", kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "pairing"] as CFDictionary)
    }
}

/// The saved half of a `PairingCode`.
struct PairingRecord: Codable, Equatable {
    var hostID: UUID
    var host: String
    var key: Data

    init(_ code: PairingCode) {
        hostID = code.hostID
        host = code.host
        key = code.key
    }

    var code: PairingCode { PairingCode(hostID: hostID, host: host, key: key) }
}
