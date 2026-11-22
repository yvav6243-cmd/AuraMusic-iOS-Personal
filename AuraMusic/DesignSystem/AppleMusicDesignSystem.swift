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

    public static let springInteractive = Animation.spring(response: 0.42, dampingFraction: 0.84, blendDuration: 0.15)
    public static let springBouncy = Animation.spring(response: 0.36, dampingFraction: 0.72, blendDuration: 0.1)
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
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(isPlayingElevated ? 0.42 : 0.14),
            radius: isPlayingElevated ? 24 : 7,
            x: 0,
            y: isPlayingElevated ? 14 : 4
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
            loadedImage = await ArtworkCacheManager.shared.image(for: url)
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
            withAnimation(.easeInOut(duration: 0.6)) {
                palette = newPalette
            }
        }
    }
}

// MARK: - Custom Vector Animated Now Playing Spectrum Bars

public struct NowPlayingEqualizerBars: View {
    public let isPlaying: Bool
    public var tint: Color = AuraTheme.accentPink

    @State private var animateBars: Bool = false

    public init(isPlaying: Bool, tint: Color = AuraTheme.accentPink) {
        self.isPlaying = isPlaying
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2.2) {
            bar(minHeight: 3, maxHeight: 13, duration: 0.45)
            bar(minHeight: 4, maxHeight: 15, duration: 0.35)
            bar(minHeight: 3, maxHeight: 11, duration: 0.52)
            bar(minHeight: 4, maxHeight: 14, duration: 0.40)
        }
        .frame(width: 16, height: 15, alignment: .bottom)
        .onAppear {
            animateBars = isPlaying
        }
        .onChange(of: isPlaying) { _, newValue in
            animateBars = newValue
        }
    }

    private func bar(minHeight: CGFloat, maxHeight: CGFloat, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
            .fill(tint)
            .frame(width: 2.4, height: animateBars ? maxHeight : minHeight)
            .animation(
                animateBars
                    ? .easeInOut(duration: duration).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: animateBars
            )
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
