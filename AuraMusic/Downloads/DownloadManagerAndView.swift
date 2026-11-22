import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WebKit

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
    public var hasOfflineLyrics: Bool
    public var syncedLyricsFingerprint: String?
    public var needsLyricsSync: Bool
    public var errorMessage: String?

    public init(
        id: String,
        track: UniversalTrack,
        state: State,
        progress: Double,
        localRelativePath: String? = nil,
        fileSizeBytes: Int64 = 0,
        hasOfflineLyrics: Bool = false,
        syncedLyricsFingerprint: String? = nil,
        needsLyricsSync: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.track = track
        self.state = state
        self.progress = progress
        self.localRelativePath = localRelativePath
        self.fileSizeBytes = fileSizeBytes
        self.hasOfflineLyrics = hasOfflineLyrics
        self.syncedLyricsFingerprint = syncedLyricsFingerprint
        self.needsLyricsSync = needsLyricsSync
        self.errorMessage = errorMessage
    }
}

public struct ExtractedYouTubeAudioResult: Sendable {
    public let candidateURLs: [URL]
    public let cookieHeader: String?
}

public struct ResolvedAudioStreamCandidate: Equatable, Sendable {
    public let url: URL
    public let itag: Int
    public let mimeType: String
    public let isProgressiveMP4: Bool
    public let durationSeconds: TimeInterval
    public let headers: [String: String]

    public init(
        url: URL,
        itag: Int = 0,
        mimeType: String = "audio/mp4",
        isProgressiveMP4: Bool = false,
        durationSeconds: TimeInterval = 0,
        headers: [String: String] = [:]
    ) {
        self.url = url
        self.itag = itag
        self.mimeType = mimeType
        self.isProgressiveMP4 = isProgressiveMP4
        self.durationSeconds = durationSeconds
        self.headers = headers
    }
}

// MARK: - Direct Fast Full-Length YouTube Innertube Audio Stream Resolver (Zero WebKit Overhead!)

public enum YouTubeInnertubeAudioResolver {
    public static let androidClientVersion = "20.10.38"
    public static let androidUserAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"

    public static func resolvePlayableStreams(videoID: String, timeoutSeconds: TimeInterval = 10.0) async -> [ResolvedAudioStreamCandidate] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let safeVideoID = String(videoID.unicodeScalars.filter { allowed.contains($0) }.prefix(24))
        guard !safeVideoID.isEmpty,
              let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return []
        }

        let payload: [String: Any] = [
            "videoId": safeVideoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": androidClientVersion,
                    "androidSdkVersion": 34,
                    "osName": "Android",
                    "osVersion": "14",
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return []
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(androidUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            return parsePlayerResponseJSON(data, headers: ["User-Agent": androidUserAgent])
        } catch {
            return []
        }
    }

    /// Parses YouTube `/youtubei/v1/player` JSON, prioritizing unthrottled HTTP-200 progressive MP4 (`itag=18`, avc1+mp4a)
    /// which downloads full-length songs in 1–3s without PO-token 403 errors and strips cleanly to lossless `.m4a` on-device.
    public static func parsePlayerResponseJSON(
        _ data: Data,
        headers: [String: String] = ["User-Agent": androidUserAgent]
    ) -> [ResolvedAudioStreamCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let playability = root["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status.uppercased() != "OK" {
            return []
        }

        let detailsDur: TimeInterval = {
            if let details = root["videoDetails"] as? [String: Any],
               let lenStr = details["lengthSeconds"] as? String,
               let secs = Double(lenStr) {
                return secs
            }
            return 0
        }()

        guard let streaming = root["streamingData"] as? [String: Any] else {
            return []
        }

        var progressiveCandidates: [ResolvedAudioStreamCandidate] = []
        if let formats = streaming["formats"] as? [[String: Any]] {
            for item in formats {
                guard let rawURL = item["url"] as? String,
                      let url = URL(string: rawURL) else { continue }
                let mime = (item["mimeType"] as? String ?? "").lowercased()
                guard mime.contains("mp4") else { continue }
                let itag = item["itag"] as? Int ?? 0
                let durMs = Double(item["approxDurationMs"] as? String ?? "") ?? 0
                let dur = durMs > 0 ? durMs / 1000.0 : detailsDur
                progressiveCandidates.append(
                    ResolvedAudioStreamCandidate(
                        url: url,
                        itag: itag,
                        mimeType: mime,
                        isProgressiveMP4: true,
                        durationSeconds: dur,
                        headers: headers
                    )
                )
            }
        }
        // Prefer itag=18 (compact 360p MP4 with 128kbps AAC audio -> fastest full-song download!)
        progressiveCandidates.sort { lhs, rhs in
            if lhs.itag == 18 && rhs.itag != 18 { return true }
            if rhs.itag == 18 && lhs.itag != 18 { return false }
            return lhs.itag < rhs.itag
        }

        var adaptiveAudioCandidates: [ResolvedAudioStreamCandidate] = []
        if let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] {
            let sortedAdaptive = adaptive.sorted { a, b in
                (a["bitrate"] as? Int ?? 0) > (b["bitrate"] as? Int ?? 0)
            }
            for item in sortedAdaptive {
                guard let rawURL = item["url"] as? String,
                      let url = URL(string: rawURL) else { continue }
                let mime = (item["mimeType"] as? String ?? "").lowercased()
                guard mime.contains("audio/mp4") else { continue }
                let itag = item["itag"] as? Int ?? 0
                let durMs = Double(item["approxDurationMs"] as? String ?? "") ?? 0
                let dur = durMs > 0 ? durMs / 1000.0 : detailsDur
                adaptiveAudioCandidates.append(
                    ResolvedAudioStreamCandidate(
                        url: url,
                        itag: itag,
                        mimeType: mime,
                        isProgressiveMP4: false,
                        durationSeconds: dur,
                        headers: headers
                    )
                )
            }
        }

        return progressiveCandidates + adaptiveAudioCandidates
    }
}

// MARK: - Off-Main-Thread Native URLSessionDownloadDelegate (Full Kernel Network Speed, 0% UI Freeze!)

private final class NativeAudioFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destinationTempURL: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(url: URL, mimeType: String, fileSize: Int64), Error>?
    private var lastProgressWallTime: TimeInterval = 0
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    init(destinationTempURL: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destinationTempURL = destinationTempURL
        self.onProgress = onProgress
        super.init()
    }

    static func download(
        request: URLRequest,
        to destinationTempURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (url: URL, mimeType: String, fileSize: Int64) {
        let downloader = NativeAudioFileDownloader(destinationTempURL: destinationTempURL, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                downloader.start(request: request, continuation: cont)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    private func start(
        request: URLRequest,
        continuation: CheckedContinuation<(url: URL, mimeType: String, fileSize: Int64), Error>
    ) {
        lock.lock()
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.name = "com.auramusic.offline.download"
        queue.maxConcurrentOperationCount = 1
        let createdSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let createdTask = createdSession.downloadTask(with: request)
        self.session = createdSession
        self.task = createdTask
        lock.unlock()
        createdTask.resume()
    }

    private func cancel() {
        lock.lock()
        let activeTask = task
        let activeSession = session
        task = nil
        session = nil
        lock.unlock()
        activeTask?.cancel()
        activeSession?.invalidateAndCancel()
        complete(with: .failure(CancellationError()))
    }

    private func complete(with result: Result<(url: URL, mimeType: String, fileSize: Int64), Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let activeSession = session
        session = nil
        task = nil
        lock.unlock()
        activeSession?.finishTasksAndInvalidate()
        switch result {
        case .success(let val):
            cont?.resume(returning: val)
        case .failure(let err):
            cont?.resume(throwing: err)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        let shouldReport = (now - lastProgressWallTime) >= 0.14
        if shouldReport {
            lastProgressWallTime = now
        }
        lock.unlock()
        if shouldReport {
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse else {
            complete(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            complete(with: .failure(NSError(
                domain: "AuraMusicOffline",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Сервер вернул HTTP \(http.statusCode)"]
            )))
            return
        }
        let mime = (http.mimeType ?? "").lowercased()
        if mime.contains("text/html") || mime.contains("application/json") || mime.contains("text/plain") {
            complete(with: .failure(URLError(.cannotDecodeContentData)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destinationTempURL)
            try FileManager.default.moveItem(at: location, to: destinationTempURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationTempURL.path)
            let size = (attrs[.size] as? Int64) ?? 0
            complete(with: .success((destinationTempURL, mime, size)))
        } catch {
            complete(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(with: .failure(error))
        }
    }
}

// MARK: - Silent Headless WebKit Full-Length Audio Stream Extractor (No Audio Output, Ad-Filtered)

@MainActor
public final class YouTubeWebKitAudioExtractor: NSObject {
    public static let shared = YouTubeWebKitAudioExtractor()

    public static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
    }

    private func acquireSlot() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    /// Cleans transient YouTube range/SABR/UMP parameters so `googlevideo.com/videoplayback` returns the complete full-length file.
    nonisolated public static func sanitizeFullLengthYouTubeStreamURL(_ rawURLString: String) -> URL? {
        guard rawURLString.contains("googlevideo.com/videoplayback") else { return nil }
        var cleaned = rawURLString
        let stripPatterns = [
            "&range=[^&]+",
            "&rn=[^&]+",
            "&rbuf=[^&]+",
            "&ump=[^&]+",
            "&srfvp=[^&]+"
        ]
        for pattern in stripPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }
        return URL(string: cleaned)
    }

    /// Extracts full-length PO-token-signed audio/mp4 & progressive video/mp4 URLs silently using a 100% muted hidden WKWebView.
    public func extractAudioStreams(videoID: String, timeoutSeconds: TimeInterval = 13.0) async -> ExtractedYouTubeAudioResult {
        await acquireSlot()
        defer { releaseSlot() }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let safeVideoID = String(videoID.unicodeScalars.filter { allowed.contains($0) }.prefix(24))
        guard !safeVideoID.isEmpty,
              let watchURL = URL(string: "https://m.youtube.com/watch?v=\(safeVideoID)") else {
            return ExtractedYouTubeAudioResult(candidateURLs: [], cookieHeader: nil)
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if let adRules = YouTubeAdBlockerRuleManager.shared.compiledRuleList {
            config.userContentController.add(adRules)
        }

        let extractorScript = """
        (function() {
          try {
            // Strip ads so we NEVER capture a 15-second pre-roll ad stream!
            function pruneAds(obj) {
              if (!obj || typeof obj !== 'object') return obj;
              if (obj.adPlacements) obj.adPlacements = [];
              if (obj.playerAds) obj.playerAds = [];
              if (obj.adSlots) obj.adSlots = [];
              if (obj.adBreakHeartbeatParams) delete obj.adBreakHeartbeatParams;
              if (obj.playerResponse && typeof obj.playerResponse === 'object') pruneAds(obj.playerResponse);
              return obj;
            }
            var _initResp = undefined;
            try {
              Object.defineProperty(window, 'ytInitialPlayerResponse', {
                get: function() { return _initResp; },
                set: function(v) {
                  _initResp = pruneAds(v);
                  try { inspectStreamingData(_initResp && _initResp.streamingData); } catch(e) {}
                },
                configurable: true
              });
            } catch(e) {}

            var origJSONParse = JSON.parse;
            JSON.parse = function() {
              var p = origJSONParse.apply(this, arguments);
              try {
                if (p && typeof p === 'object') {
                  if (p.adPlacements || p.playerAds || p.adSlots || p.playerResponse) pruneAds(p);
                  if (p.streamingData) inspectStreamingData(p.streamingData);
                }
              } catch(e) {}
              return p;
            };

            // Lock audio strictly muted inside the hidden extractor WebView so downloading never interrupts active music!
            var origMutedDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
            Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
              get: function() { return true; },
              set: function() {
                try { if (origMutedDesc && origMutedDesc.set) origMutedDesc.set.call(this, true); } catch(e) {}
              },
              configurable: true
            });
            Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
              get: function() { return 0; },
              set: function() {},
              configurable: true
            });

            var seen = {};
            function reportURL(rawUrl, kind) {
              if (!rawUrl || typeof rawUrl !== 'string') return;
              if (rawUrl.indexOf('googlevideo.com/videoplayback') === -1) return;
              var mp = document.getElementById('movie_player');
              if (mp && (mp.classList.contains('ad-showing') || mp.classList.contains('ad-interrupting'))) return;
              var clean = rawUrl.replace(/&range=[^&]+/g, '').replace(/&rn=[^&]+/g, '').replace(/&rbuf=[^&]+/g, '').replace(/&ump=[^&]+/g, '').replace(/&srfvp=[^&]+/g, '');
              if (seen[clean]) return;
              seen[clean] = true;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.auraExtract) {
                window.webkit.messageHandlers.auraExtract.postMessage({ url: clean, kind: kind });
              }
            }

            function inspectStreamingData(sd) {
              if (!sd || typeof sd !== 'object') return;
              var adaptive = sd.adaptiveFormats || [];
              for (var i = 0; i < adaptive.length; i++) {
                var f = adaptive[i];
                if (f && f.url && f.mimeType && f.mimeType.indexOf('audio/mp4') !== -1) {
                  reportURL(f.url, 'audio_mp4');
                }
              }
              var progressive = sd.formats || [];
              for (var j = 0; j < progressive.length; j++) {
                var pf = progressive[j];
                if (pf && pf.url && pf.mimeType && pf.mimeType.indexOf('video/mp4') !== -1) {
                  reportURL(pf.url, 'video_mp4');
                }
              }
            }

            function classifyAndReport(u) {
              if (!u || typeof u !== 'string') return;
              if (u.indexOf('googlevideo.com/videoplayback') === -1) return;
              if (u.indexOf('mime=audio/mp4') !== -1 || u.indexOf('mime%3Daudio%2Fmp4') !== -1) {
                reportURL(u, 'audio_mp4');
              } else if (u.indexOf('mime=video/mp4') !== -1 || u.indexOf('mime%3Dvideo%2Fmp4') !== -1) {
                reportURL(u, 'video_mp4');
              } else if (u.indexOf('mime=audio') !== -1 || u.indexOf('mime%3Daudio') !== -1) {
                reportURL(u, 'audio_other');
              }
            }

            var origFetch = window.fetch;
            if (origFetch) {
              window.fetch = function(input) {
                try {
                  var u = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
                  classifyAndReport(u);
                } catch(e) {}
                return origFetch.apply(this, arguments);
              };
            }
            var origOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
              try { classifyAndReport(url); } catch(e) {}
              return origOpen.apply(this, arguments);
            };

            setInterval(function() {
              try {
                var v = document.querySelector('video');
                if (v) {
                  v.setAttribute('muted', '');
                  v.setAttribute('playsinline', '');
                  if (origMutedDesc && origMutedDesc.set) origMutedDesc.set.call(v, true);
                  if (v.currentSrc && v.currentSrc.indexOf('http') === 0) {
                    classifyAndReport(v.currentSrc);
                  }
                  if (v.paused) {
                    var mp = document.getElementById('movie_player');
                    if (mp && mp.playVideo) { try { mp.playVideo(); } catch(e) {} }
                    try { v.play().catch(function(){}); } catch(e) {}
                  }
                }
              } catch(e) {}
            }, 250);
          } catch(e) {}
        })();
        """

        let script = WKUserScript(source: extractorScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        final class MessageReceiver: NSObject, WKScriptMessageHandler {
            var audioMP4: [URL] = []
            var videoMP4: [URL] = []
            var onStrongCandidate: (() -> Void)?

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let dict = message.body as? [String: Any],
                      let urlStr = dict["url"] as? String,
                      let kind = dict["kind"] as? String,
                      let url = URL(string: urlStr) else {
                    return
                }
                if kind == "audio_mp4" {
                    if !audioMP4.contains(url) { audioMP4.append(url) }
                    onStrongCandidate?()
                } else if kind == "video_mp4" {
                    if !videoMP4.contains(url) { videoMP4.append(url) }
                }
            }
        }

        let receiver = MessageReceiver()
        config.userContentController.add(receiver, name: "auraExtract")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.alpha = 0.002
        webView.isUserInteractionEnabled = false

        // Attach invisibly to active window so iOS WebKit executes JS & network requests without background throttling
        let hostWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        hostWindow?.addSubview(webView)

        defer {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "auraExtract")
            webView.removeFromSuperview()
        }

        var request = URLRequest(url: watchURL)
        request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
        webView.load(request)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            var timeoutTask: Task<Void, Never>?

            let finish: @MainActor () -> Void = {
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                receiver.onStrongCandidate = nil
                cont.resume()
            }

            receiver.onStrongCandidate = {
                // Give 450ms for any secondary progressive MP4 URL to arrive as backup, then finish immediately!
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    finish()
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finish()
            }
        }

        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let relevantCookies = cookies.filter {
            let dom = $0.domain.lowercased()
            return dom.contains("youtube.com") || dom.contains("google.com") || dom.contains("googlevideo.com")
        }
        let cookieHeader: String? = relevantCookies.isEmpty
            ? nil
            : relevantCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        // Prefer progressive video/mp4 (doesn't hit PO-token 403 on plain GET!) before adaptive audio/mp4
        let combined = receiver.videoMP4 + receiver.audioMP4
        if let firstAudio = receiver.audioMP4.first {
            UniversalAudioPlayerEngine.shared.recordCapturedYouTubeAudioStreamURL(firstAudio, forVideoID: safeVideoID)
        }
        return ExtractedYouTubeAudioResult(candidateURLs: combined, cookieHeader: cookieHeader)
    }
}

// MARK: - Full-Length Offline Audio + Synchronized Lyrics + Cover Download Manager

@MainActor
public final class OfflineDownloadManager: NSObject, ObservableObject {
    public static let shared = OfflineDownloadManager()

    @Published public private(set) var tasks: [DownloadTaskItem] = []
    @Published public private(set) var totalDownloadedBytes: Int64 = 0

    private var activeSwiftTasks: [String: Task<Void, Never>] = [:]
    private var pendingTracksQueue: [UniversalTrack] = []
    private let maxConcurrentDownloads = 2
    private let fileManager = FileManager.default
    private let downloadsDirectoryName = "AuraDownloads"
    private let audiusProvider = AudiusProvider()
    private let ytMusicProvider = YouTubeMusicProvider(providerType: .youtubeMusic)
    private let matcher = TrackMatchingEngine()

    private override init() {
        super.init()
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
                    let hasLyrics = LyricsService.shared.hasCachedLyrics(for: track) || (LyricsService.shared.loadCachedCustomLyrics(for: track) != nil)
                    let fingerprint = LyricsService.shared.activeLyricsFingerprint(for: track)
                    tasks.append(
                        DownloadTaskItem(
                            id: track.id,
                            track: track,
                            state: .completed,
                            progress: 1.0,
                            localRelativePath: relPath,
                            fileSizeBytes: size,
                            hasOfflineLyrics: hasLyrics,
                            syncedLyricsFingerprint: fingerprint,
                            needsLyricsSync: !hasLyrics,
                            errorMessage: nil
                        )
                    )
                }
            }
        }
        recalculateStorageBytes()
    }

    // MARK: - Offline Availability & Cross-Provider Lookup (Always Prefer Offline First!)

    public func isDownloaded(_ trackID: String) -> Bool {
        tasks.contains { $0.id == trackID && $0.state == .completed }
    }

    public func isDownloaded(_ track: UniversalTrack) -> Bool {
        completedLocalRelativePath(for: track) != nil
    }

    /// Returns true if a downloaded track has missing or newly changed lyrics (e.g. after switching to AI lyrics or manual LRCLIB pick)
    /// so the UI can show a 1-tap "Докачать лирику" button without re-downloading audio!
    public func hasLyricsUpdateAvailable(for track: UniversalTrack) -> Bool {
        guard let item = matchingCompletedTask(for: track) else { return false }
        if item.needsLyricsSync || !item.hasOfflineLyrics {
            return true
        }
        let latest = LyricsService.shared.activeLyricsFingerprint(for: track)
        if let latest, latest != item.syncedLyricsFingerprint {
            return true
        }
        return false
    }

    /// Called whenever lyrics change for a track (AI lyrics generated, manual LRCLIB pick, or mode switched).
    public func notifyLyricsChanged(for track: UniversalTrack) {
        let latest = LyricsService.shared.activeLyricsFingerprint(for: track)
        for idx in tasks.indices where tasks[idx].state == .completed && taskMatches(tasks[idx], track: track) {
            if latest != tasks[idx].syncedLyricsFingerprint {
                tasks[idx].needsLyricsSync = true
            }
        }
    }

    /// Syncs / downloads updated lyrics & latest cover artwork into offline storage for a downloaded song WITHOUT re-downloading audio!
    /// If the song isn't downloaded yet, enqueues the full offline download (audio + lyrics + cover).
    public func syncOfflineLyricsForTrack(_ track: UniversalTrack) async {
        guard isDownloaded(track) else {
            enqueueDownload(for: track)
            return
        }
        let mode = LyricsService.shared.preferredLyricsMode(for: track)
        var gotLyrics = false
        if mode == .custom, LyricsService.shared.loadCachedCustomLyrics(for: track) != nil {
            gotLyrics = true
        } else {
            gotLyrics = await LyricsService.shared.prefetchAndCacheLyrics(for: track)
        }
        await ArtworkCacheManager.shared.prefetchArtwork(for: PersistenceController.shared.effectiveArtworkURL(for: track))
        let latestFingerprint = LyricsService.shared.activeLyricsFingerprint(for: track)

        for idx in tasks.indices where tasks[idx].state == .completed && taskMatches(tasks[idx], track: track) {
            tasks[idx].hasOfflineLyrics = gotLyrics || (latestFingerprint != nil)
            tasks[idx].syncedLyricsFingerprint = latestFingerprint
            tasks[idx].needsLyricsSync = false
        }
    }

    private func taskMatches(_ item: DownloadTaskItem, track: UniversalTrack) -> Bool {
        if item.id == track.id { return true }
        if !track.providerTrackID.isEmpty && item.track.providerTrackID == track.providerTrackID { return true }
        return matcher.isSameSong(item.track, track)
    }

    private func matchingCompletedTask(for track: UniversalTrack) -> DownloadTaskItem? {
        tasks.first { $0.state == .completed && taskMatches($0, track: track) }
    }

    public func isDownloadingOrQueued(_ track: UniversalTrack) -> Bool {
        tasks.contains { $0.id == track.id && ($0.state == .downloading || $0.state == .queued) }
    }

    public func completedLocalRelativePath(for trackID: String) -> String? {
        if let completed = tasks.first(where: { $0.id == trackID && $0.state == .completed }),
           let rel = completed.localRelativePath,
           localFileExists(relativePath: rel) {
            return rel
        }
        if let rel = PersistenceController.shared.libraryTracks.first(where: { $0.trackID == trackID })?.localFileRelativePath,
           localFileExists(relativePath: rel) {
            return rel
        }
        return nil
    }

    /// Resolves a downloaded local audio file for `track` by exact ID, matching `providerTrackID` (e.g. youtube ↔ youtubeMusic),
    /// OR identical song metadata (`TrackMatchingEngine.isSameSong`), so even when online, offline files ALWAYS play first!
    public func completedLocalRelativePath(for track: UniversalTrack) -> String? {
        if let direct = track.localFileRelativePath, localFileExists(relativePath: direct) {
            return direct
        }
        if let byID = completedLocalRelativePath(for: track.id) {
            return byID
        }
        if !track.providerTrackID.isEmpty,
           let byProviderID = tasks.first(where: {
               $0.state == .completed && $0.track.providerTrackID == track.providerTrackID
           }),
           let rel = byProviderID.localRelativePath,
           localFileExists(relativePath: rel) {
            return rel
        }
        if let bySameSong = tasks.first(where: {
            $0.state == .completed && matcher.isSameSong(track, $0.track)
        }),
           let rel = bySameSong.localRelativePath,
           localFileExists(relativePath: rel) {
            return rel
        }
        return nil
    }

    public func playlistDownloadSummary(for tracks: [UniversalTrack]) -> (completed: Int, active: Int, total: Int) {
        var completed = 0
        var active = 0
        for track in tracks {
            if isDownloaded(track) {
                completed += 1
            } else if isDownloadingOrQueued(track) {
                active += 1
            }
        }
        return (completed, active, tracks.count)
    }

    /// Strictly rejects 30-second previews or 15-second ad clips whenever the track is a full-length song (>= 60s).
    nonisolated public static func isFullLengthDurationValid(
        actualDuration: TimeInterval,
        expectedTrackDuration: TimeInterval
    ) -> Bool {
        guard actualDuration.isFinite, actualDuration >= 5.0 else { return false }
        if expectedTrackDuration >= 60.0 {
            // Never accept a 30-second preview or short clip for a full-length song!
            return actualDuration >= 45.0
        }
        return true
    }

    private func localFileExists(relativePath: String) -> Bool {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(relativePath)
        return fileManager.fileExists(atPath: url.path)
    }

    /// Helper used by tests to register a verified completed offline download cleanly.
    internal func registerCompletedDownloadForTesting(track: UniversalTrack, relativePath: String, fileSizeBytes: Int64 = 3_500_000, hasLyrics: Bool = true) {
        tasks.removeAll { $0.id == track.id }
        tasks.insert(
            DownloadTaskItem(
                id: track.id,
                track: track,
                state: .completed,
                progress: 1.0,
                localRelativePath: relativePath,
                fileSizeBytes: fileSizeBytes,
                hasOfflineLyrics: hasLyrics,
                errorMessage: nil
            ),
            at: 0
        )
    }

    // MARK: - Enqueue Individual Track or Entire Playlist (Audio + Lyrics + Cover!)

    public func enqueueDownload(for track: UniversalTrack) {
        if isDownloaded(track) {
            // Even if audio is already downloaded, sync any updated lyrics (AI or manual) & latest artwork immediately!
            Task {
                await self.syncOfflineLyricsForTrack(track)
            }
            return
        }

        if let existingIdx = tasks.firstIndex(where: { $0.id == track.id }) {
            if tasks[existingIdx].state == .downloading || tasks[existingIdx].state == .queued {
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
            hasOfflineLyrics: LyricsService.shared.hasCachedLyrics(for: track),
            errorMessage: nil
        )
        tasks.insert(item, at: 0)
        pendingTracksQueue.append(track)
        pumpDownloadQueue()
    }

    public func enqueuePlaylistDownload(tracks: [UniversalTrack]) {
        for track in tracks {
            enqueueDownload(for: track)
        }
    }

    private func pumpDownloadQueue() {
        while activeSwiftTasks.count < maxConcurrentDownloads, !pendingTracksQueue.isEmpty {
            let nextTrack = pendingTracksQueue.removeFirst()
            guard tasks.contains(where: { $0.id == nextTrack.id && $0.state == .queued }) else {
                continue
            }
            let job = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performFullTrackOfflineDownload(for: nextTrack)
                self.activeSwiftTasks.removeValue(forKey: nextTrack.id)
                self.pumpDownloadQueue()
            }
            activeSwiftTasks[nextTrack.id] = job
        }
    }

    /// Helper used by integration tests to execute & await the complete real offline download pipeline cleanly.
    internal func downloadTrackNowForTesting(_ track: UniversalTrack) async -> DownloadTaskItem? {
        if isDownloaded(track) {
            return tasks.first { $0.id == track.id && $0.state == .completed }
        }
        tasks.removeAll { $0.id == track.id }
        let item = DownloadTaskItem(
            id: track.id,
            track: track,
            state: .queued,
            progress: 0.0,
            localRelativePath: nil,
            fileSizeBytes: 0,
            hasOfflineLyrics: LyricsService.shared.hasCachedLyrics(for: track),
            errorMessage: nil
        )
        tasks.insert(item, at: 0)
        await performFullTrackOfflineDownload(for: track)
        return tasks.first { $0.id == track.id }
    }

    private func performFullTrackOfflineDownload(for track: UniversalTrack) async {
        updateTask(id: track.id) {
            $0.state = .downloading
            $0.progress = 0.04
            $0.errorMessage = nil
        }

        // 1. Download synchronized lyrics + cover artwork in parallel with the full-length audio!
        async let lyricsPrefetch: Bool = LyricsService.shared.prefetchAndCacheLyrics(for: track)
        async let artworkPrefetch: Void = ArtworkCacheManager.shared.prefetchArtwork(for: PersistenceController.shared.effectiveArtworkURL(for: track))

        // 2. Resolve ONLY FULL-LENGTH audio candidates (NEVER 30-second iTunes previews!)
        let audioCandidates = await resolveFullLengthAudioCandidates(for: track)
        guard !Task.isCancelled else { return }

        var savedRelativePath: String? = nil
        var savedFileSize: Int64 = 0
        var lastError: String? = nil

        for candidate in audioCandidates {
            guard !Task.isCancelled else { return }
            do {
                let (relPath, bytes) = try await downloadAndVerifyFullLengthAudio(
                    candidate: candidate,
                    for: track
                )
                savedRelativePath = relPath
                savedFileSize = bytes
                break
            } catch {
                lastError = error.localizedDescription
            }
        }

        let cachedLyrics = await lyricsPrefetch
        await artworkPrefetch
        guard !Task.isCancelled else { return }

        if let relPath = savedRelativePath {
            let latestFP = LyricsService.shared.activeLyricsFingerprint(for: track)
            updateTask(id: track.id) {
                $0.state = .completed
                $0.progress = 1.0
                $0.localRelativePath = relPath
                $0.fileSizeBytes = savedFileSize
                $0.hasOfflineLyrics = cachedLyrics || (latestFP != nil)
                $0.syncedLyricsFingerprint = latestFP
                $0.needsLyricsSync = false
                $0.errorMessage = nil
            }
            var updatedTrack = track
            updatedTrack.localFileRelativePath = relPath
            PersistenceController.shared.upsertTrack(updatedTrack, addToLibrary: true)
            recalculateStorageBytes()
        } else {
            updateTask(id: track.id) {
                $0.state = .failed
                $0.hasOfflineLyrics = cachedLyrics
                $0.errorMessage = lastError ?? "Не удалось скачать полную версию трека (30-сек превью отключены)."
            }
        }
    }

    private func resolveFullLengthAudioCandidates(for track: UniversalTrack) async -> [ResolvedAudioStreamCandidate] {
        var candidates: [ResolvedAudioStreamCandidate] = []

        func appendUnique(_ candidate: ResolvedAudioStreamCandidate) {
            if !candidates.contains(where: { $0.url == candidate.url }) {
                candidates.append(candidate)
            }
        }

        // A. Direct full-length providers (Audius / SoundCloud)
        if track.provider == .audius {
            if let stream = try? await audiusProvider.resolvePlayableStreamURL(for: track) {
                appendUnique(ResolvedAudioStreamCandidate(url: stream, mimeType: "audio/mpeg"))
            }
            return candidates
        }
        if track.provider == .soundCloud, let direct = track.streamURL, track.isStreamable {
            appendUnique(ResolvedAudioStreamCandidate(url: direct, mimeType: "audio/mpeg"))
        }

        // B. Build ordered YouTube videoIDs (direct videoID first, or via YouTube Music search for Apple Music / Spotify!)
        var targetVideoIDs: [String] = []
        if (track.provider == .youtubeMusic || track.provider == .youtube), !track.providerTrackID.isEmpty {
            targetVideoIDs.append(track.providerTrackID)
        }

        if targetVideoIDs.isEmpty {
            let query = "\(track.title) \(track.artist)"
            if let ytMatches = try? await ytMusicProvider.searchTracks(query: query, limit: 3) {
                for match in ytMatches where !match.providerTrackID.isEmpty {
                    if !targetVideoIDs.contains(match.providerTrackID) {
                        targetVideoIDs.append(match.providerTrackID)
                    }
                }
            }
        }

        // C. PRIMARY ULTRA-FAST RESOLVER: YouTube ANDROID Innertube API -> HTTP 200 full-length progressive MP4 (itag=18)!
        updateTask(id: track.id) { $0.progress = 0.08 }
        for vid in targetVideoIDs.prefix(2) {
            let resolved = await YouTubeInnertubeAudioResolver.resolvePlayableStreams(videoID: vid)
            for stream in resolved {
                appendUnique(stream)
            }
            if candidates.contains(where: \.isProgressiveMP4) {
                break
            }
        }

        // If primary YouTube track ID was region/age restricted, automatically try alternate YouTube Music audio uploads!
        if !candidates.contains(where: \.isProgressiveMP4),
           (track.provider == .youtubeMusic || track.provider == .youtube) {
            let query = "\(track.title) \(track.artist)"
            if let backups = try? await ytMusicProvider.searchTracks(query: query, limit: 3) {
                for backup in backups where !backup.providerTrackID.isEmpty && !targetVideoIDs.contains(backup.providerTrackID) {
                    let resolved = await YouTubeInnertubeAudioResolver.resolvePlayableStreams(videoID: backup.providerTrackID)
                    for stream in resolved {
                        appendUnique(stream)
                    }
                    if candidates.contains(where: \.isProgressiveMP4) {
                        break
                    }
                }
            }
        }

        // D. SECONDARY FALLBACK: Silent muted WebKit extractor ONLY if Innertube yielded no progressive candidate
        if !candidates.contains(where: \.isProgressiveMP4), let primaryVid = targetVideoIDs.first {
            updateTask(id: track.id) { $0.progress = 0.12 }
            let extracted = await YouTubeWebKitAudioExtractor.shared.extractAudioStreams(videoID: primaryVid, timeoutSeconds: 10.0)
            var safariHeaders: [String: String] = [
                "User-Agent": YouTubeWebKitAudioExtractor.safariUserAgent,
                "Referer": "https://m.youtube.com/",
                "Origin": "https://m.youtube.com",
                "Accept": "*/*"
            ]
            if let cookie = extracted.cookieHeader, !cookie.isEmpty {
                safariHeaders["Cookie"] = cookie
            }
            for url in extracted.candidateURLs {
                let lower = url.absoluteString.lowercased()
                let isProg = lower.contains("mime=video/mp4") || lower.contains("mime%3dvideo%2fmp4")
                appendUnique(
                    ResolvedAudioStreamCandidate(
                        url: url,
                        mimeType: isProg ? "video/mp4" : "audio/mp4",
                        isProgressiveMP4: isProg,
                        headers: safariHeaders
                    )
                )
            }
        }

        // E. TERTIARY FALLBACK: Exact full-length Audius 320kbps MP3 (ONLY exact song match with duration >= 60s — NEVER 30s previews!)
        if candidates.isEmpty {
            let query = "\(track.title) \(track.artist)"
            if let openMatches = try? await audiusProvider.searchTracks(query: query, limit: 5),
               let exactOpen = openMatches.first(where: { matcher.isSameSong(track, $0) && $0.duration >= 60 }),
               let audiusURL = try? await audiusProvider.resolvePlayableStreamURL(for: exactOpen) {
                appendUnique(ResolvedAudioStreamCandidate(url: audiusURL, mimeType: "audio/mpeg"))
            }
        }

        // NOTE: NEVER fall back to AppleMusicProvider (30-second iTunes preview)!
        return candidates
    }

    /// Strips any video track off-main-thread into a pure compact lossless AAC `.m4a` using AVMutableComposition + Passthrough
    /// (~80ms, zero re-encoding), falling back cleanly to `AVAssetExportPresetAppleM4A` if needed.
    nonisolated public static func extractAudioOnlyM4A(from sourceURL: URL, to destinationURL: URL) async -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceAudio = audioTracks.first else { return false }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { return false }

            let composition = AVMutableComposition()
            guard let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                return false
            }
            try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)

            try? FileManager.default.removeItem(at: destinationURL)
            if let passthrough = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
               passthrough.supportedFileTypes.contains(.m4a) {
                passthrough.outputURL = destinationURL
                passthrough.outputFileType = .m4a
                passthrough.shouldOptimizeForNetworkUse = true
                await passthrough.export()
                if passthrough.status == .completed && FileManager.default.fileExists(atPath: destinationURL.path) {
                    return true
                }
            }

            try? FileManager.default.removeItem(at: destinationURL)
            if let transcoder = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                transcoder.outputURL = destinationURL
                transcoder.outputFileType = .m4a
                await transcoder.export()
                if transcoder.status == .completed && FileManager.default.fileExists(atPath: destinationURL.path) {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    private func downloadAndVerifyFullLengthAudio(
        candidate: ResolvedAudioStreamCandidate,
        for track: UniversalTrack
    ) async throws -> (relativePath: String, fileSize: Int64) {
        var request = URLRequest(url: candidate.url)
        request.timeoutInterval = 90
        for (key, value) in candidate.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let isMP3Hint = candidate.mimeType.contains("mpeg") || candidate.url.pathExtension.lowercased() == "mp3"
        let isVideoHint = candidate.isProgressiveMP4 || candidate.mimeType.contains("video/mp4")
        let tempExt = isMP3Hint ? "mp3" : (isVideoHint ? "mp4" : "m4a")

        let safeBase = track.id
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeBase)_\(UUID().uuidString).\(tempExt)")

        let trackID = track.id
        let downloaded = try await NativeAudioFileDownloader.download(request: request, to: tempURL) { [weak self] written, expected in
            let ratio: Double = expected > 0
                ? 0.12 + 0.78 * min(1.0, Double(written) / Double(expected))
                : min(0.86, 0.18 + Double(written) / 6_000_000.0)
            Task { @MainActor [weak self] in
                self?.updateTask(id: trackID) {
                    $0.progress = max($0.progress, ratio)
                    $0.fileSizeBytes = written
                }
            }
        }

        let writtenBytes = downloaded.fileSize
        // Reject tiny/corrupt error payloads (< 100 KB)
        guard writtenBytes >= 100_000 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.dataLengthExceedsMaximum)
        }

        // Verify real playability & FULL-LENGTH duration via AVURLAsset (strictly rejects 30s previews / ad clips!)
        let asset = AVURLAsset(url: tempURL)
        let (isPlayable, loadedDuration, allTracks) = try await asset.load(.isPlayable, .duration, .tracks)
        let actualDuration = loadedDuration.seconds
        guard isPlayable,
              Self.isFullLengthDurationValid(actualDuration: actualDuration, expectedTrackDuration: track.duration) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "AuraMusicOffline",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Отклонён неполный файл (\(Int(actualDuration.isFinite ? actualDuration : 0)) сек) — требуется полная песня."]
            )
        }

        let isMP3 = isMP3Hint || downloaded.mimeType.contains("mpeg")
        let hasVideoTrack = allTracks.contains { $0.mediaType == .video }
        let finalExt = isMP3 ? "mp3" : "m4a"
        let relativePath = "\(downloadsDirectoryName)/\(safeBase).\(finalExt)"
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = docs.appendingPathComponent(relativePath)
        try? fileManager.removeItem(at: destinationURL)

        if hasVideoTrack {
            // Strip video track locally on-device into compact lossless .m4a audio (~2.5–4 MB instead of 10+ MB!)
            updateTask(id: track.id) { $0.progress = 0.93 }
            let extractedM4A = await Self.extractAudioOnlyM4A(from: tempURL, to: destinationURL)
            if extractedM4A && fileManager.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
                let finalSize = (try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? writtenBytes
                return (relativePath, finalSize)
            }
            // Fallback: keep progressive MP4 directly if export wasn't supported (AVPlayer still plays it audio-only!)
            let mp4Relative = "\(downloadsDirectoryName)/\(safeBase).mp4"
            let mp4Dest = docs.appendingPathComponent(mp4Relative)
            try? fileManager.removeItem(at: mp4Dest)
            try fileManager.moveItem(at: tempURL, to: mp4Dest)
            let finalSize = (try? fileManager.attributesOfItem(atPath: mp4Dest.path)[.size] as? Int64) ?? writtenBytes
            return (mp4Relative, finalSize)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            let finalSize = (try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? writtenBytes
            return (relativePath, finalSize)
        }
    }

    public func pauseDownload(trackID: String) {
        activeSwiftTasks[trackID]?.cancel()
        activeSwiftTasks.removeValue(forKey: trackID)
        pendingTracksQueue.removeAll { $0.id == trackID }
        updateTask(id: trackID) {
            $0.state = .paused
        }
        pumpDownloadQueue()
    }

    public func resumeDownload(trackID: String) {
        guard let item = tasks.first(where: { $0.id == trackID }) else { return }
        updateTask(id: trackID) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        if !pendingTracksQueue.contains(where: { $0.id == trackID }) {
            pendingTracksQueue.append(item.track)
        }
        pumpDownloadQueue()
    }

    public func removeDownload(trackID: String) {
        activeSwiftTasks[trackID]?.cancel()
        activeSwiftTasks.removeValue(forKey: trackID)
        pendingTracksQueue.removeAll { $0.id == trackID }

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
        pumpDownloadQueue()
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
                        Text("\(downloadManager.tasks.filter { $0.state == .completed }.count) full tracks • \(formattedStorageUsed)")
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
                Text("Скачанные треки сохраняются полностью вместе с синхронизированным текстом и обложкой. Даже при наличии интернета AuraMusic воспроизводит скачанный офлайн-файл мгновенно и без рекламы.")
            }

            if !downloadManager.tasks.isEmpty {
                Section("Download Queue & Offline Tracks") {
                    ForEach(downloadManager.tasks) { item in
                        HStack(spacing: 12) {
                            AuraArtworkView(url: PersistenceController.shared.effectiveArtworkURL(for: item.track), size: 48, cornerRadius: 8)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.track.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(item.track.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if item.state == .downloading || item.state == .paused || item.state == .queued {
                                    ProgressView(value: item.progress)
                                        .tint(AuraTheme.accentPink)
                                } else if let err = item.errorMessage {
                                    Text(err)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                } else {
                                    HStack(spacing: 6) {
                                        if item.fileSizeBytes > 0 {
                                            Text(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                        if item.hasOfflineLyrics && !downloadManager.hasLyricsUpdateAvailable(for: item.track) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "quote.bubble.fill")
                                                    .font(.system(size: 8.5, weight: .bold))
                                                Text("Текст сохранён")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .lineLimit(1)
                                            }
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }

                                    if downloadManager.hasLyricsUpdateAvailable(for: item.track) {
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            Task {
                                                await downloadManager.syncOfflineLyricsForTrack(item.track)
                                            }
                                        } label: {
                                            Label("Докачать обновлённую лирику", systemImage: "arrow.down.circle.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(AuraTheme.accentPink)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.top, 2)
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
                                Button {
                                    downloadManager.resumeDownload(trackID: item.id)
                                } label: {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.orange)
                                }
                                .buttonStyle(.plain)
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
