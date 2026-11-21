import Foundation
import MusicKit
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsAndPersonalizationView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @ObservedObject var credentials: ProviderCredentialsStore = .shared
    @ObservedObject var persistence: PersistenceController = .shared
    @ObservedObject var downloadManager: OfflineDownloadManager = .shared

    @State private var musicKitStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @State private var showBackupExporter: Bool = false
    @State private var showBackupImporter: Bool = false
    @State private var backupDocument: JSONBackupFileDocument?
    @State private var statusBanner: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                if let statusBanner {
                    Section {
                        Text(statusBanner)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                    }
                }

                // 1. Audio Playback & Quality
                Section("Audio Quality & Playback Engine") {
                    Picker("Streaming Quality", selection: $player.streamingQuality) {
                        ForEach(AudioStreamingQuality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }

                    Toggle("Gapless Playback", isOn: $player.isGaplessEnabled)
                        .tint(AuraTheme.accentPink)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Crossfade Transitions")
                            Spacer()
                            Text(player.crossfadeSeconds < 0.5 ? "Off" : String(format: "%.0f sec", player.crossfadeSeconds))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $player.crossfadeSeconds, in: 0...12, step: 1)
                            .tint(AuraTheme.accentPink)
                    }
                }

                // 2. Equalizer & Sleep Timer
                Section("Equalizer & Sleep Timer") {
                    Picker("EQ Preset", selection: $player.equalizerPreset) {
                        ForEach(EqualizerPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }

                    HStack(spacing: 12) {
                        ForEach(Array(["60Hz", "150Hz", "400Hz", "1kHz", "2.4kHz", "15kHz"].enumerated()), id: \.offset) { idx, label in
                            let gain = player.equalizerPreset.bandGainsDB[idx]
                            VStack(spacing: 4) {
                                Text(String(format: "%+.0fdB", gain))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AuraTheme.accentPink)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(AuraTheme.accentPink.opacity(0.75))
                                    .frame(width: 8, height: CGFloat(max(8, 24 + gain * 3)))
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 6)

                    Menu {
                        Button("Off") { player.setSleepTimer(minutes: nil) }
                        Button("15 Minutes") { player.setSleepTimer(minutes: 15) }
                        Button("30 Minutes") { player.setSleepTimer(minutes: 30) }
                        Button("45 Minutes") { player.setSleepTimer(minutes: 45) }
                        Button("60 Minutes") { player.setSleepTimer(minutes: 60) }
                    } label: {
                        HStack {
                            Label("Sleep Timer", systemImage: "moon.zzz.fill")
                            Spacer()
                            if let remaining = player.sleepTimerRemainingSeconds {
                                Text("\(remaining / 60)m \(remaining % 60)s")
                                    .foregroundStyle(AuraTheme.accentPink)
                                    .fontWeight(.semibold)
                            } else {
                                Text("Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 3. Music Provider Connections & Legitimate API Keys
                Section("Music Providers & API Authorization") {
                    HStack {
                        Label("Apple MusicKit Status", systemImage: "apple.logo")
                        Spacer()
                        Text(String(describing: musicKitStatus).capitalized)
                            .foregroundStyle(.secondary)
                        Button("Authorize") {
                            Task {
                                musicKitStatus = await AppleMusicProvider().requestMusicKitAuthorization()
                            }
                        }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AuraTheme.accentPink)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("YouTube Data API v3 Key (Optional — enables live YouTube & YT Music search)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("AIzaSy...", text: $credentials.youtubeAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spotify Web API OAuth Bearer Token (Optional — enables Spotify catalog & ISRC matching)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("BQD...", text: $credentials.spotifyAccessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SoundCloud API OAuth / Client ID (Optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("SoundCloud OAuth Token", text: $credentials.soundCloudClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                // 4. Platform Capabilities & Legal Transparency
                Section("Provider Capabilities & Playback Transparency") {
                    ForEach(MusicProviderType.allCases) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                ProviderBadgePill(provider: provider)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { credentials.isProviderEnabled(provider) },
                                    set: { credentials.setProvider(provider, enabled: $0) }
                                ))
                                .labelsHidden()
                                .tint(AuraTheme.accentPink)
                            }
                            Text(provider.limitationExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }

                // 5. Personal Library Backup, Restore & Storage
                Section("Personal Library Backup & Storage") {
                    Button {
                        if let data = try? persistence.exportBackupJSONData() {
                            backupDocument = JSONBackupFileDocument(data: data)
                            showBackupExporter = true
                        }
                    } label: {
                        Label("Export Library & Playlists Backup (.json)", systemImage: "arrow.up.doc.fill")
                    }

                    Button {
                        showBackupImporter = true
                    } label: {
                        Label("Restore Library from Backup (.json)", systemImage: "arrow.down.doc.fill")
                    }

                    HStack {
                        Text("Artwork Disk Cache")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: ArtworkCacheManager.shared.currentDiskCacheBytes(), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            ArtworkCacheManager.shared.clearCache()
                            statusBanner = "Artwork cache cleared."
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
            }
            .navigationTitle("Settings")
            .fileExporter(
                isPresented: $showBackupExporter,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "AuraMusic_Personal_Backup.json"
            ) { result in
                if case .success = result {
                    statusBanner = "Personal library backup exported successfully."
                }
            }
            .fileImporter(
                isPresented: $showBackupImporter,
                allowedContentTypes: [.json]
            ) { result in
                if case .success(let fileURL) = result {
                    let accessed = fileURL.startAccessingSecurityScopedResource()
                    defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: fileURL) {
                        try? persistence.importBackupJSONData(data)
                        statusBanner = "Personal library and playlists restored."
                    }
                }
            }
        }
    }
}

public struct JSONBackupFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
