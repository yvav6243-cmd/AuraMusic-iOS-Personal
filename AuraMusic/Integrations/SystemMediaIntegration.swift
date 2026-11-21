import AVKit
import Foundation
import MediaPlayer
import SwiftUI
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Native AirPlay & Bluetooth Output Route Picker

public struct AirPlayRoutePickerButton: UIViewRepresentable {
    public var tintColor: UIColor

    public init(tintColor: UIColor = .white) {
        self.tintColor = tintColor
    }

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor
        picker.activeTintColor = UIColor(red: 0.98, green: 0.14, blue: 0.23, alpha: 1.0)
        picker.prioritizesVideoDevices = false
        return picker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}

// MARK: - Native System Volume Slider Bridge (MPVolumeView)

public struct HardwareVolumeSliderBridge: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsVolumeSlider = true
        return volumeView
    }

    public func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Native iOS Share Sheet (UIActivityViewController)

public struct SystemShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]

    public init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Dynamic Island / Live Activity Attributes & Manager

#if canImport(ActivityKit)
public struct AuraNowPlayingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var album: String
        public var providerBadge: String
        public var isPlaying: Bool
        public var elapsedSeconds: Int
        public var durationSeconds: Int

        public init(
            title: String,
            artist: String,
            album: String,
            providerBadge: String,
            isPlaying: Bool,
            elapsedSeconds: Int,
            durationSeconds: Int
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.providerBadge = providerBadge
            self.isPlaying = isPlaying
            self.elapsedSeconds = elapsedSeconds
            self.durationSeconds = durationSeconds
        }
    }

    public var sessionIdentifier: String
    public init(sessionIdentifier: String = "AuraMusicNowPlaying") {
        self.sessionIdentifier = sessionIdentifier
    }
}
#endif

@MainActor
public final class DynamicIslandNowPlayingCoordinator {
    public static let shared = DynamicIslandNowPlayingCoordinator()

    private init() {}

    public func updateLiveActivity(track: UniversalTrack?, isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard let track else {
                Task {
                    for activity in Activity<AuraNowPlayingAttributes>.activities {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
                return
            }

            let state = AuraNowPlayingAttributes.ContentState(
                title: track.title,
                artist: track.artist,
                album: track.album,
                providerBadge: track.provider.shortBadgeName,
                isPlaying: isPlaying,
                elapsedSeconds: Int(max(0, currentTime)),
                durationSeconds: Int(max(0, duration))
            )

            if let existing = Activity<AuraNowPlayingAttributes>.activities.first {
                Task {
                    await existing.update(ActivityContent(state: state, staleDate: nil))
                }
            } else {
                let attributes = AuraNowPlayingAttributes()
                let content = ActivityContent(state: state, staleDate: nil)
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        }
        #endif
    }
}
