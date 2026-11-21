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

    /// Inspects all available API keys & authorizations and automatically ranks the active providers
    public func refreshActiveProviderPriority() {
        var ranked: [MusicProviderType] = []

        // 1. Local files are always highest priority if present
        ranked.append(.localFile)

        // 2. If Apple MusicKit is authorized with subscription, prioritize native Apple MusicKit
        if MusicAuthorization.currentStatus == .authorized && enabledProviders.contains(.appleMusic) {
            ranked.append(.appleMusic)
        }

        // 3. If YouTube Data API v3 key is present, prioritize YouTube Music full studio audio
        if !youtubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if enabledProviders.contains(.youtubeMusic) {
                ranked.append(.youtubeMusic)
            }
            if enabledProviders.contains(.youtube) {
                ranked.append(.youtube)
            }
        }

        // 4. If SoundCloud OAuth token is present, include SoundCloud full streams
        if !soundCloudClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           enabledProviders.contains(.soundCloud) {
            ranked.append(.soundCloud)
        }

        // 5. Audius Open Hi-Fi Catalog is always available 100% key-free for full 320kbps streams
        if enabledProviders.contains(.audius) {
            ranked.append(.audius)
        }

        // 6. If Spotify token is present, include Spotify catalog
        if !spotifyAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           enabledProviders.contains(.spotify) {
            ranked.append(.spotify)
        }

        // 7. Apple Music Public Catalog (for metadata, charts, 600x600 artwork & AAC preview fallback)
        if !ranked.contains(.appleMusic) && enabledProviders.contains(.appleMusic) {
            ranked.append(.appleMusic)
        }

        // 8. Live Internet Radio
        if enabledProviders.contains(.radio) {
            ranked.append(.radio)
        }

        self.activePriorityProviders = ranked
        self.primaryAutoSelectedProvider = ranked.first { $0 != .localFile } ?? .audius
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
