import AVFoundation
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

// MARK: - Native System Volume Controller & Styled MPVolumeView Slider

@MainActor
public final class SystemVolumeController {
    public static let shared = SystemVolumeController()

    private weak var activeVolumeSlider: UISlider?
    private lazy var fallbackVolumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 28))
        view.alpha = 0.01
        return view
    }()

    private init() {}

    public func registerSlider(_ slider: UISlider?) {
        guard let slider else { return }
        self.activeVolumeSlider = slider
    }

    public static func clampedVolume(_ value: Float) -> Float {
        guard value.isFinite else { return 0.5 }
        return max(0.0, min(1.0, value))
    }

    public func currentHardwareVolume() -> Float {
        if let slider = activeVolumeSlider {
            return Self.clampedVolume(slider.value)
        }
        return Self.clampedVolume(AVAudioSession.sharedInstance().outputVolume)
    }

    @discardableResult
    public func setSystemVolume(_ target: Float) -> Float {
        let clamped = Self.clampedVolume(target)
        let slider = activeVolumeSlider
            ?? fallbackVolumeView.subviews.compactMap { $0 as? UISlider }.first
        if let slider {
            slider.setValue(clamped, animated: true)
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
        }
        UniversalAudioPlayerEngine.shared.syncObservedHardwareVolume(clamped)
        return clamped
    }

    @discardableResult
    public func stepVolume(by delta: Float) -> Float {
        let next = Self.clampedVolume(currentHardwareVolume() + delta)
        return setSystemVolume(next)
    }
}

public final class AuraSystemVolumeContainerView: UIView {
    public let volumeView = MPVolumeView(frame: .zero)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        configureVolumeView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        clipsToBounds = false
        configureVolumeView()
    }

    private func configureVolumeView() {
        volumeView.showsVolumeSlider = true
        volumeView.tintColor = .white
        volumeView.clipsToBounds = false

        let minTrack = Self.makeCapsuleTrackImage(color: UIColor.white.withAlphaComponent(0.92), height: 6)
        let maxTrack = Self.makeCapsuleTrackImage(color: UIColor.white.withAlphaComponent(0.24), height: 6)
        let thumbNormal = Self.makeThumbImage(diameter: 16)
        let thumbHighlighted = Self.makeThumbImage(diameter: 19)

        volumeView.setMinimumVolumeSliderImage(minTrack, for: .normal)
        volumeView.setMaximumVolumeSliderImage(maxTrack, for: .normal)
        volumeView.setVolumeThumbImage(thumbNormal, for: .normal)
        volumeView.setVolumeThumbImage(thumbHighlighted, for: .highlighted)

        addSubview(volumeView)
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let found = findSlider(in: child) { return found }
        }
        return nil
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let sliderHeight: CGFloat = 28
        let yOffset = max(0, (bounds.height - sliderHeight) * 0.5)
        volumeView.frame = CGRect(x: 0, y: yOffset, width: bounds.width, height: sliderHeight)

        if let slider = Self.findSlider(in: volumeView) {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.24)
            SystemVolumeController.shared.registerSlider(slider)
        }
        for subview in volumeView.subviews where subview is UIButton {
            // AirPlay output picker already lives in the bottom control bar
            subview.isHidden = true
        }
    }

    public static func makeCapsuleTrackImage(color: UIColor, height: CGFloat) -> UIImage {
        let width: CGFloat = 16
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: height / 2)
            color.setFill()
            path.fill()
        }
        let inset = height / 2
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset))
    }

    public static func makeThumbImage(diameter: CGFloat) -> UIImage {
        let padding: CGFloat = 4
        let canvas = CGSize(width: diameter + padding * 2, height: diameter + padding * 2)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setShadow(
                offset: CGSize(width: 0, height: 1.5),
                blur: 3.5,
                color: UIColor.black.withAlphaComponent(0.28).cgColor
            )
            let circleRect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
            UIColor.white.setFill()
            cg.fillEllipse(in: circleRect)
        }
    }
}

public struct HardwareVolumeSliderBridge: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> AuraSystemVolumeContainerView {
        AuraSystemVolumeContainerView(frame: .zero)
    }

    public func updateUIView(_ uiView: AuraSystemVolumeContainerView, context: Context) {
        uiView.setNeedsLayout()
    }
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
        // Native iPhone Dynamic Island Music UI (album artwork on leading side + real-time audio bass/spectrum
        // waveform on trailing side) is rendered directly by iOS MediaRemote/SpringBoard whenever the app runs
        // AVAudioSession(.playback, mode: .default, policy: .longFormAudio, options: []) + MPNowPlayingInfoCenter.
        // Dismiss any leftover empty ActivityKit Live Activities so they never shadow the system Music Island!
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            let existing = Activity<AuraNowPlayingAttributes>.activities
            if !existing.isEmpty {
                Task {
                    for activity in existing {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        }
        #endif
    }
}
