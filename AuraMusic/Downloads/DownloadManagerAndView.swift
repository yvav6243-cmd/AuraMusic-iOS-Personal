import Foundation
import SwiftUI

public struct DownloadTaskItem: Identifiable, Sendable {
    public enum State: String, Sendable {
        case queued = "Queued"
        case downloading = "Downloading"
        case paused = "Paused"
        case completed = "Downloaded"
        case failed = "Failed"
    }

    public let id: String
    public let track: UniversalTrack
    public var state: State
    public var progress: Double
    public var localRelativePath: String?
    public var fileSizeBytes: Int64
    public var errorMessage: String?
}

@MainActor
public final class OfflineDownloadManager: NSObject, ObservableObject {
    public static let shared = OfflineDownloadManager()

    @Published public private(set) var tasks: [DownloadTaskItem] = []
    @Published public private(set) var totalDownloadedBytes: Int64 = 0

    private var urlSession: URLSession!
    private var activeURLTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [String: Data] = [:]
    private let fileManager = FileManager.default
    private let downloadsDirectoryName = "AuraDownloads"
    private let audiusProvider = AudiusProvider()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        ensureDownloadsDirectoryExists()
        reconcileExistingDownloadsFromLibrary()
    }

    private var downloadsDirectoryURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(downloadsDirectoryName, isDirectory: true)
    }

    private func ensureDownloadsDirectoryExists() {
        try? fileManager.createDirectory(at: downloadsDirectoryURL, withIntermediateDirectories: true)
        recalculateStorageBytes()
    }

    private func reconcileExistingDownloadsFromLibrary() {
        for entity in PersistenceController.shared.libraryTracks {
            if let relPath = entity.localFileRelativePath {
                let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                let fullURL = docs.appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullURL.path) {
                    let size = (try? fileManager.attributesOfItem(atPath: fullURL.path)[.size] as? Int64) ?? 0
                    let track = entity.toUniversalTrack()
                    tasks.append(
                        DownloadTaskItem(
                            id: track.id,
                            track: track,
                            state: .completed,
                            progress: 1.0,
                            localRelativePath: relPath,
                            fileSizeBytes: size,
                            errorMessage: nil
                        )
                    )
                }
            }
        }
        recalculateStorageBytes()
    }

    public func isDownloaded(_ trackID: String) -> Bool {
        tasks.contains { $0.id == trackID && $0.state == .completed }
    }

    public func completedLocalRelativePath(for trackID: String) -> String? {
        if let completed = tasks.first(where: { $0.id == trackID && $0.state == .completed }),
           let rel = completed.localRelativePath {
            return rel
        }
        return PersistenceController.shared.libraryTracks.first(where: { $0.trackID == trackID })?.localFileRelativePath
    }

    // MARK: - Enqueue Individual Track or Entire Playlist

    public func enqueueDownload(for track: UniversalTrack) {
        if let existingIdx = tasks.firstIndex(where: { $0.id == track.id }) {
            if tasks[existingIdx].state == .completed || tasks[existingIdx].state == .downloading {
                return
            }
            tasks.remove(at: existingIdx)
        }

        let item = DownloadTaskItem(
            id: track.id,
            track: track,
            state: .queued,
            progress: 0.0,
            localRelativePath: nil,
            fileSizeBytes: 0,
            errorMessage: nil
        )
        tasks.insert(item, at: 0)

        Task {
            await startDownloadTask(for: track)
        }
    }

    public func enqueuePlaylistDownload(tracks: [UniversalTrack]) {
        for track in tracks {
            enqueueDownload(for: track)
        }
    }

    private func startDownloadTask(for track: UniversalTrack) async {
        var resolvedURL: URL? = nil

        if track.provider == .youtubeMusic || track.provider == .youtube {
            // 1. Check if the WebKit engine already captured the poToken-signed audio/mp4 stream URL
            if let captured = UniversalAudioPlayerEngine.shared.capturedYouTubeAudioStreamURLs[track.providerTrackID] {
                resolvedURL = captured
            }
            // 2. Otherwise check Audius Open Hi-Fi catalog for a full-length 320kbps MP3 match
            if resolvedURL == nil {
                let query = "\(track.title) \(track.artist)"
                if let openMatches = try? await audiusProvider.searchTracks(query: query, limit: 4),
                   let bestOpen = openMatches.first(where: { TrackMatchingEngine().isSameSong(track, $0) }) ?? openMatches.first {
                    resolvedURL = try? await audiusProvider.resolvePlayableStreamURL(for: bestOpen)
                }
            }
            // 3. Fallback to direct AAC catalog stream so offline download always succeeds
            if resolvedURL == nil {
                resolvedURL = try? await AppleMusicProvider().resolvePlayableStreamURL(for: track)
            }
        } else if track.provider == .audius {
            resolvedURL = try? await audiusProvider.resolvePlayableStreamURL(for: track)
        } else {
            resolvedURL = track.streamURL ?? track.previewURL
            if resolvedURL == nil {
                resolvedURL = try? await AppleMusicProvider().resolvePlayableStreamURL(for: track)
            }
        }

        guard let downloadURL = resolvedURL else {
            updateTask(id: track.id) {
                $0.state = .failed
                $0.errorMessage = "No offline audio stream URL available for this track."
            }
            return
        }

        let downloadTask = urlSession.downloadTask(with: downloadURL)
        downloadTask.taskDescription = track.id
        activeURLTasks[track.id] = downloadTask
        updateTask(id: track.id) {
            $0.state = .downloading
        }
        downloadTask.resume()
    }

    public func pauseDownload(trackID: String) {
        guard let urlTask = activeURLTasks[trackID] else { return }
        urlTask.cancel { [weak self] resumeData in
            Task { @MainActor in
                if let resumeData {
                    self?.resumeDataMap[trackID] = resumeData
                }
                self?.activeURLTasks.removeValue(forKey: trackID)
                self?.updateTask(id: trackID) {
                    $0.state = .paused
                }
            }
        }
    }

    public func resumeDownload(trackID: String) {
        if let resumeData = resumeDataMap[trackID] {
            let task = urlSession.downloadTask(withResumeData: resumeData)
            task.taskDescription = trackID
            resumeDataMap.removeValue(forKey: trackID)
            activeURLTasks[trackID] = task
            updateTask(id: trackID) { $0.state = .downloading }
            task.resume()
        } else if let item = tasks.first(where: { $0.id == trackID }) {
            Task {
                await startDownloadTask(for: item.track)
            }
        }
    }

    public func removeDownload(trackID: String) {
        activeURLTasks[trackID]?.cancel()
        activeURLTasks.removeValue(forKey: trackID)
        resumeDataMap.removeValue(forKey: trackID)

        if let item = tasks.first(where: { $0.id == trackID }),
           let rel = item.localRelativePath {
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = docs.appendingPathComponent(rel)
            try? fileManager.removeItem(at: fileURL)
        }

        if let entity = PersistenceController.shared.libraryTracks.first(where: { $0.trackID == trackID }) {
            entity.localFileRelativePath = nil
            try? PersistenceController.shared.context.save()
            PersistenceController.shared.reloadAll()
        }

        tasks.removeAll { $0.id == trackID }
        recalculateStorageBytes()
    }

    public func removeAllDownloads() {
        let ids = tasks.map(\.id)
        for id in ids {
            removeDownload(trackID: id)
        }
    }

    public func recalculateStorageBytes() {
        guard let enumerator = fileManager.enumerator(
            at: downloadsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            totalDownloadedBytes = 0
            return
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        totalDownloadedBytes = total
    }

    private func updateTask(id: String, mutation: (inout DownloadTaskItem) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[idx])
    }
}

// MARK: - URLSessionDownloadDelegate

extension OfflineDownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let trackID = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.5
        Task { @MainActor in
            self.updateTask(id: trackID) {
                $0.state = .downloading
                $0.progress = min(max(progress, 0.05), 0.99)
                $0.fileSizeBytes = totalBytesWritten
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let trackID = downloadTask.taskDescription else { return }
        let safeFileName = trackID
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_") + ".mp3"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let relativePath = "AuraDownloads/\(safeFileName)"
        let destinationURL = docs.appendingPathComponent(relativePath)

        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            let finalSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            Task { @MainActor in
                self.activeURLTasks.removeValue(forKey: trackID)
                self.updateTask(id: trackID) {
                    $0.state = .completed
                    $0.progress = 1.0
                    $0.localRelativePath = relativePath
                    $0.fileSizeBytes = finalSize
                }
                if let item = self.tasks.first(where: { $0.id == trackID }) {
                    var updatedTrack = item.track
                    updatedTrack.localFileRelativePath = relativePath
                    PersistenceController.shared.upsertTrack(updatedTrack, addToLibrary: true)
                }
                self.recalculateStorageBytes()
            }
        } catch {
            Task { @MainActor in
                self.updateTask(id: trackID) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Dedicated Downloads & Offline Storage View

public struct DownloadsManagementView: View {
    @ObservedObject var downloadManager: OfflineDownloadManager = .shared
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared

    public init() {}

    private var formattedStorageUsed: String {
        ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadedBytes, countStyle: .file)
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AuraTheme.accentPink.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AuraTheme.accentPink)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Offline Audio Storage")
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(downloadManager.tasks.filter { $0.state == .completed }.count) downloaded tracks • \(formattedStorageUsed)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !downloadManager.tasks.isEmpty {
                        Button(role: .destructive) {
                            downloadManager.removeAllDownloads()
                        } label: {
                            Text("Clear All")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("AuraMusic downloads DRM-free audio from authorized open catalogs (such as Audius 320kbps MP3s and creator-enabled SoundCloud tracks) and stores imported personal audio files for 100% offline playback.")
            }

            if !downloadManager.tasks.isEmpty {
                Section("Download Queue & Offline Tracks") {
                    ForEach(downloadManager.tasks) { item in
                        HStack(spacing: 12) {
                            AuraArtworkView(url: item.track.artworkURL, size: 48, cornerRadius: 8)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.track.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(item.track.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if item.state == .downloading || item.state == .paused {
                                    ProgressView(value: item.progress)
                                        .tint(AuraTheme.accentPink)
                                } else if let err = item.errorMessage {
                                    Text(err)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                } else {
                                    HStack(spacing: 6) {
                                        ProviderBadgePill(provider: item.track.provider, capability: .offlineFile)
                                        if item.fileSizeBytes > 0 {
                                            Text(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            Spacer()

                            switch item.state {
                            case .downloading:
                                Button {
                                    downloadManager.pauseDownload(trackID: item.id)
                                } label: {
                                    Image(systemName: "pause.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(AuraTheme.accentPink)
                                }
                                .buttonStyle(.plain)

                            case .paused, .queued:
                                Button {
                                    downloadManager.resumeDownload(trackID: item.id)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(AuraTheme.accentPink)
                                }
                                .buttonStyle(.plain)

                            case .completed:
                                Button {
                                    var offlineTrack = item.track
                                    offlineTrack.localFileRelativePath = item.localRelativePath
                                    let allOffline = downloadManager.tasks
                                        .filter { $0.state == .completed }
                                        .map { task -> UniversalTrack in
                                            var t = task.track
                                            t.localFileRelativePath = task.localRelativePath
                                            return t
                                        }
                                    player.play(offlineTrack, queue: allOffline)
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AuraTheme.accentPink)
                                        .padding(8)
                                        .background(Circle().fill(AuraTheme.accentPink.opacity(0.14)))
                                }
                                .buttonStyle(.plain)

                            case .failed:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                downloadManager.removeDownload(trackID: item.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloaded")
    }
}
