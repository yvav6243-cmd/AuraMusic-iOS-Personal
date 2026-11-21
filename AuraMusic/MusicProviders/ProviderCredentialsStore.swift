import Foundation
import MusicKit
import Security

@MainActor
public final class ProviderCredentialsStore: ObservableObject {
    public static let shared = ProviderCredentialsStore()

    @Published public var appleMusicDeveloperToken: String {
        didSet {
            saveKeychain(key: "aura.token.appleMusic", value: appleMusicDeveloperToken)
            refreshActiveProviderPriority()
        }
    }
    @Published public var youtubeAPIKey: String {
        didSet {
            saveKeychain(key: "aura.token.youtube", value: youtubeAPIKey)
            refreshActiveProviderPriority()
        }
    }
    @Published public var spotifyClientID: String {
        didSet {
            saveKeychain(key: "aura.token.spotifyClientID", value: spotifyClientID)
            refreshActiveProviderPriority()
        }
    }
    @Published public var spotifyAccessToken: String {
        didSet {
            saveKeychain(key: "aura.token.spotifyAccess", value: spotifyAccessToken)
            refreshActiveProviderPriority()
        }
    }
    @Published public var soundCloudClientID: String {
        didSet {
            saveKeychain(key: "aura.token.soundcloud", value: soundCloudClientID)
            refreshActiveProviderPriority()
        }
    }

    @Published public var enabledProviders: Set<MusicProviderType> = Set(MusicProviderType.allCases)
    /// Ordered list of currently active & configured providers, updated automatically whenever API keys change
    @Published public private(set) var activePriorityProviders: [MusicProviderType] = []
    @Published public private(set) var primaryAutoSelectedProvider: MusicProviderType = .audius

    private init() {
        self.appleMusicDeveloperToken = Self.readKeychain(key: "aura.token.appleMusic") ?? ""
        let savedYT = Self.readKeychain(key: "aura.token.youtube") ?? ""
        let verifiedWorkingYTKey = "AIzaSyCHoPSdrgYinPSDvIn1dbIFyWjnLdgJ8ww"
        let resolvedYTKey: String
        if savedYT.isEmpty || savedYT == "AIzaSyCQhB2utBO9vGfh_dl1fmv3Aya-cd33FfQ" {
            resolvedYTKey = verifiedWorkingYTKey
        } else {
            resolvedYTKey = savedYT
        }
        self.youtubeAPIKey = resolvedYTKey
        self.spotifyClientID = Self.readKeychain(key: "aura.token.spotifyClientID") ?? ""
        self.spotifyAccessToken = Self.readKeychain(key: "aura.token.spotifyAccess") ?? ""
        self.soundCloudClientID = Self.readKeychain(key: "aura.token.soundcloud") ?? ""
        saveKeychain(key: "aura.token.youtube", value: resolvedYTKey)
        refreshActiveProviderPriority()
    }

    /// Returns true ONLY if this provider has an active, configured API ready for full playback
    public func hasConfiguredAPI(for provider: MusicProviderType) -> Bool {
        switch provider {
        case .localFile, .radio:
            return true
        case .youtubeMusic, .youtube:
            return !youtubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .appleMusic:
            return MusicAuthorization.currentStatus == .authorized ||
                   !appleMusicDeveloperToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .soundCloud:
            return !soundCloudClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .spotify:
            return !spotifyAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .audius:
            // Show Audius automatically only if no mainstream API (YouTube / Apple MusicKit / SoundCloud / Spotify) is configured
            let hasMainstreamAPI = hasConfiguredAPI(for: .youtubeMusic) ||
                                   hasConfiguredAPI(for: .appleMusic) ||
                                   hasConfiguredAPI(for: .soundCloud) ||
                                   hasConfiguredAPI(for: .spotify)
            return !hasMainstreamAPI
        }
    }

    public var configuredCatalogProviders: [MusicProviderType] {
        var result: [MusicProviderType] = []
        for provider in [MusicProviderType.youtubeMusic, .youtube, .appleMusic, .soundCloud, .spotify, .audius] {
            if enabledProviders.contains(provider) && hasConfiguredAPI(for: provider) {
                result.append(provider)
            }
        }
        if result.isEmpty {
            result.append(.audius)
        }
        return result
    }

    /// Inspects all available API keys & authorizations and automatically ranks ONLY the configured providers
    public func refreshActiveProviderPriority() {
        var ranked: [MusicProviderType] = [.localFile]
        ranked.append(contentsOf: configuredCatalogProviders)
        self.activePriorityProviders = ranked
        self.primaryAutoSelectedProvider = configuredCatalogProviders.first ?? .youtubeMusic
    }

    public func isProviderReadyForFullPlayback(_ provider: MusicProviderType) -> Bool {
        switch provider {
        case .localFile, .audius, .radio:
            return true
        case .appleMusic:
            return MusicAuthorization.currentStatus == .authorized
        case .youtubeMusic, .youtube:
            return !youtubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .soundCloud:
            return !soundCloudClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .spotify:
            return false
        }
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
        refreshActiveProviderPriority()
    }

    // MARK: - Keychain Storage (Hardware-Encrypted on iPhone)

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
