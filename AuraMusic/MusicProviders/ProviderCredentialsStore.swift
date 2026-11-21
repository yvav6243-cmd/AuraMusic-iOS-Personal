import Foundation
import Security

@MainActor
public final class ProviderCredentialsStore: ObservableObject {
    public static let shared = ProviderCredentialsStore()

    @Published public var appleMusicDeveloperToken: String {
        didSet { saveKeychain(key: "aura.token.appleMusic", value: appleMusicDeveloperToken) }
    }
    @Published public var youtubeAPIKey: String {
        didSet { saveKeychain(key: "aura.token.youtube", value: youtubeAPIKey) }
    }
    @Published public var spotifyClientID: String {
        didSet { saveKeychain(key: "aura.token.spotifyClientID", value: spotifyClientID) }
    }
    @Published public var spotifyAccessToken: String {
        didSet { saveKeychain(key: "aura.token.spotifyAccess", value: spotifyAccessToken) }
    }
    @Published public var soundCloudClientID: String {
        didSet { saveKeychain(key: "aura.token.soundcloud", value: soundCloudClientID) }
    }

    @Published public var enabledProviders: Set<MusicProviderType> = Set(MusicProviderType.allCases)

    private init() {
        self.appleMusicDeveloperToken = Self.readKeychain(key: "aura.token.appleMusic") ?? ""
        self.youtubeAPIKey = Self.readKeychain(key: "aura.token.youtube") ?? ""
        self.spotifyClientID = Self.readKeychain(key: "aura.token.spotifyClientID") ?? ""
        self.spotifyAccessToken = Self.readKeychain(key: "aura.token.spotifyAccess") ?? ""
        self.soundCloudClientID = Self.readKeychain(key: "aura.token.soundcloud") ?? ""
    }

    public func isProviderEnabled(_ provider: MusicProviderType) -> Bool {
        enabledProviders.contains(provider)
    }

    public func setProvider(_ provider: MusicProviderType, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
    }

    // MARK: - Keychain Storage (Never exposes API keys in source code)

    private func saveKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(insertQuery as CFDictionary, nil)
    }

    public nonisolated static func readKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
