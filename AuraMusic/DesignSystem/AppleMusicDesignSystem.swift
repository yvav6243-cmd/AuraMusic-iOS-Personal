import SwiftUI

// MARK: - Apple Music Inspired Design Tokens

public enum AuraTheme {
    public static let accentPink = Color(red: 0.98, green: 0.14, blue: 0.23) // #FA233B
    public static let accentCrimson = Color(red: 0.88, green: 0.09, blue: 0.25)
    public static let secondaryLabel = Color.secondary

    public static let cardCornerRadius: CGFloat = 12
    public static let artworkCornerRadius: CGFloat = 10
    public static let expandedArtworkCornerRadius: CGFloat = 16
    public static let miniPlayerHeight: CGFloat = 60
    public static let horizontalMargin: CGFloat = 20

    public static let springInteractive = Animation.spring(response: 0.38, dampingFraction: 0.86, blendDuration: 0.08)
    public static let springPlayerSheet = Animation.spring(response: 0.44, dampingFraction: 0.89, blendDuration: 0.08)
    public static let springPlayerDismiss = Animation.spring(response: 0.46, dampingFraction: 0.92, blendDuration: 0.06)
    public static let springBouncy = Animation.spring(response: 0.36, dampingFraction: 0.78, blendDuration: 0.08)
    public static let springSnappy = Animation.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.05)
}

// MARK: - Cached Artwork View with Apple Music Specular Rim & Shadow

public struct AuraArtworkView: View, Equatable {
    public let url: URL?
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public var isPlayingElevated: Bool = false
    public var placeholderSymbol: String = "music.note"

    @State private var loadedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    public static func == (lhs: AuraArtworkView, rhs: AuraArtworkView) -> Bool {
        lhs.url == rhs.url &&
        lhs.size == rhs.size &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isPlayingElevated == rhs.isPlayingElevated &&
        lhs.placeholderSymbol == rhs.placeholderSymbol
    }

    public init(
        url: URL?,
        size: CGFloat,
        cornerRadius: CGFloat = AuraTheme.artworkCornerRadius,
        isPlayingElevated: Bool = false,
        placeholderSymbol: String = "music.note"
    ) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.isPlayingElevated = isPlayingElevated
        self.placeholderSymbol = placeholderSymbol
        self._loadedImage = State(initialValue: ArtworkCacheManager.shared.cachedMemoryImage(for: url))
    }

    public var body: some View {
        let displayImage = loadedImage ?? ArtworkCacheManager.shared.cachedMemoryImage(for: url)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(white: 0.18), Color(white: 0.11)]
                            : [Color(white: 0.92), Color(white: 0.84)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(isPlayingElevated ? 0.42 : (size <= 64 ? 0.10 : 0.15)),
            radius: isPlayingElevated ? 24 : (size <= 64 ? 3 : 7),
            x: 0,
            y: isPlayingElevated ? 14 : (size <= 64 ? 1.5 : 4)
        )
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                return
            }
            if let memHit = ArtworkCacheManager.shared.cachedMemoryImage(for: url) {
                loadedImage = memHit
                return
            }
            let fetched = await ArtworkCacheManager.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) {
                loadedImage = fetched
            }
        }
    }
}

/// Adaptive 1:1 square artwork view that automatically fills any flexible LazyVGrid column cleanly across SE, 6.1", and Pro Max screens.
public struct AuraFlexibleArtworkView: View, Equatable {
    public let url: URL?
    public var cornerRadius: CGFloat = AuraTheme.artworkCornerRadius
    public var placeholderSymbol: String = "music.note"

    @State private var loadedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    public static func == (lhs: AuraFlexibleArtworkView, rhs: AuraFlexibleArtworkView) -> Bool {
        lhs.url == rhs.url &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.placeholderSymbol == rhs.placeholderSymbol
    }

    public init(url: URL?, cornerRadius: CGFloat = AuraTheme.artworkCornerRadius, placeholderSymbol: String = "music.note") {
        self.url = url
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
        self._loadedImage = State(initialValue: ArtworkCacheManager.shared.cachedMemoryImage(for: url))
    }

    public var body: some View {
        let displayImage = loadedImage ?? ArtworkCacheManager.shared.cachedMemoryImage(for: url)
        GeometryReader { geo in
            let side = max(geo.size.width, 1)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(white: 0.18), Color(white: 0.11)]
                                : [Color(white: 0.92), Color(white: 0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                if let displayImage {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: side * 0.32, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 7, x: 0, y: 4)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                return
            }
            if let memHit = ArtworkCacheManager.shared.cachedMemoryImage(for: url) {
                loadedImage = memHit
                return
            }
            let fetched = await ArtworkCacheManager.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) {
                loadedImage = fetched
            }
        }
    }
}

/// Unified playlist cover renderer that always honors custom user photo covers first, then remote cover, then first track artwork.
/// Uses cached ImageIO Retina decoding + O(1) track artwork lookup so scroll frames stay locked at 120 FPS!
@MainActor
public struct AuraPlaylistCoverView: View {
    public let playlist: PersistedPlaylistEntity
    public let size: CGFloat
    public var cornerRadius: CGFloat = 10

    public init(playlist: PersistedPlaylistEntity, size: CGFloat, cornerRadius: CGFloat = 10) {
        self.playlist = playlist
        self.size = size
        self.cornerRadius = cornerRadius
    }

    private var fallbackTrackArtworkURL: URL? {
        guard let firstID = playlist.orderedTrackIDs.first else { return nil }
        return PersistenceController.shared.effectiveArtworkURL(forTrackID: firstID)
    }

    public var body: some View {
        let targetMaxPixels = max(256, (size * 3.0).rounded())
        if let customData = playlist.customCoverImageData,
           let uiImage = ArtworkCacheManager.shared.cachedPlaylistCoverImage(
               playlistID: playlist.playlistID,
               data: customData,
               maxPixelSize: min(960, targetMaxPixels)
           ) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(
                    color: Color.black.opacity(size <= 64 ? 0.10 : 0.16),
                    radius: size <= 64 ? 3 : 8,
                    x: 0,
                    y: size <= 64 ? 1.5 : 4
                )
        } else {
            AuraArtworkView(
                url: playlist.coverArtworkURLString.flatMap(URL.init(string:)) ?? fallbackTrackArtworkURL,
                size: size,
                cornerRadius: cornerRadius,
                placeholderSymbol: playlist.isSmartPlaylist ? "gearshape.2.fill" : "music.note.list"
            )
            .equatable()
        }
    }
}

// MARK: - Animated Apple Music Fluid Artwork Mesh Background

public struct DynamicArtworkMeshBackground: View, Equatable {
    public let artworkURL: URL?
    public var isAnimating: Bool = true

    @State private var palette: [Color]

    public static func == (lhs: DynamicArtworkMeshBackground, rhs: DynamicArtworkMeshBackground) -> Bool {
        lhs.artworkURL == rhs.artworkURL && lhs.isAnimating == rhs.isAnimating
    }

    public init(artworkURL: URL?, isAnimating: Bool = true) {
        self.artworkURL = artworkURL
        self.isAnimating = isAnimating
        let defaultPalette: [Color] = [
            Color(red: 0.98, green: 0.14, blue: 0.23),
            Color(red: 0.42, green: 0.09, blue: 0.38),
            Color(red: 0.12, green: 0.08, blue: 0.22),
            Color(red: 0.06, green: 0.06, blue: 0.10)
        ]
        self._palette = State(initialValue: ArtworkCacheManager.shared.cachedDominantColors(for: artworkURL) ?? defaultPalette)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09)

                LinearGradient(
                    colors: [palette[0].opacity(0.68), palette[1].opacity(0.58), palette[2].opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [palette[0].opacity(0.55), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: proxy.size.width * 0.95
                )

                RadialGradient(
                    colors: [palette[1].opacity(0.50), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: proxy.size.width * 0.95
                )

                Color.black.opacity(0.28)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .task(id: artworkURL) {
            let newPalette = await ArtworkCacheManager.shared.dominantColors(for: artworkURL)
            withAnimation(.easeInOut(duration: 0.72)) {
                palette = newPalette
            }
        }
    }
}

// MARK: - Custom Vector Animated Now Playing Spectrum Bars (100% GPU Transform -> 0% Layout CPU)

public struct NowPlayingEqualizerBars: View, Equatable {
    public let isPlaying: Bool
    public var tint: Color = AuraTheme.accentPink

    @State private var animateBars: Bool = false

    public static func == (lhs: NowPlayingEqualizerBars, rhs: NowPlayingEqualizerBars) -> Bool {
        lhs.isPlaying == rhs.isPlaying && lhs.tint == rhs.tint
    }

    public init(isPlaying: Bool, tint: Color = AuraTheme.accentPink) {
        self.isPlaying = isPlaying
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2.2) {
            bar(minScale: 0.20, maxScale: 0.88, duration: 0.44)
            bar(minScale: 0.26, maxScale: 1.00, duration: 0.34)
            bar(minScale: 0.20, maxScale: 0.74, duration: 0.50)
            bar(minScale: 0.26, maxScale: 0.94, duration: 0.39)
        }
        .frame(width: 16, height: 15, alignment: .bottom)
        .onAppear {
            animateBars = isPlaying
        }
        .onChange(of: isPlaying) { _, newValue in
            animateBars = newValue
        }
    }

    private func bar(minScale: CGFloat, maxScale: CGFloat, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
            .fill(tint)
            .frame(width: 2.4, height: 15)
            .scaleEffect(y: animateBars ? maxScale : minScale, anchor: .bottom)
            .animation(
                animateBars
                    ? .easeInOut(duration: duration).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.18),
                value: animateBars
            )
    }
}

/// Isolated track-row title + live GPU equalizer indicator observing ONLY `TrackPlaybackHighlightState.shared`.
/// Eliminates list-row invalidation storms when opening/closing the player, dragging, scrubbing, or changing volume!
public struct TrackRowTitleWithEqualizer: View {
    public let trackID: String
    public let title: String
    public var explicit: Bool = false

    @ObservedObject private var highlightState: TrackPlaybackHighlightState = .shared

    public init(trackID: String, title: String, explicit: Bool = false) {
        self.trackID = trackID
        self.title = title
        self.explicit = explicit
    }

    public var body: some View {
        let isCurrent = (highlightState.activeTrackID == trackID)
        HStack(spacing: 6) {
            if isCurrent {
                NowPlayingEqualizerBars(isPlaying: highlightState.isPlaying)
                    .equatable()
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCurrent ? AuraTheme.accentPink : .primary)
                .lineLimit(1)
            if explicit {
                Text("E")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2)))
            }
        }
        .animation(AuraTheme.springSnappy, value: isCurrent)
    }
}

// MARK: - Provider & Audio Capability Pill Badge

public struct ProviderBadgePill: View {
    public let provider: MusicProviderType
    public var capability: PlaybackCapability?

    public init(provider: MusicProviderType, capability: PlaybackCapability? = nil) {
        self.provider = provider
        self.capability = capability
    }

    public static func formattedLabel(provider: MusicProviderType, capability: PlaybackCapability?) -> String {
        if let cap = capability?.shortPillLabel {
            return "\(provider.shortBadgeName) • \(cap)"
        }
        return provider.shortBadgeName
    }

    public var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: provider.systemIconName)
                .font(.system(size: 8.5, weight: .bold))
            Text(Self.formattedLabel(provider: provider, capability: capability))
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(provider.badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(provider.badgeColor.opacity(0.14))
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}

public struct OfflineStatusBadgePill: View {
    public var text: String = "OFFLINE"

    public init(text: String = "OFFLINE") {
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.green.opacity(0.15))
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}

// MARK: - Apple Music Section Header

public struct AppleMusicSectionHeader: View {
    public let title: String
    public var subtitle: String? = nil
    public var actionTitle: String? = nil
    public var action: (() -> Void)? = nil

    public init(
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: { action?() }) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.primary)
                        if action != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuraTheme.accentPink)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AuraTheme.horizontalMargin)
    }
}
