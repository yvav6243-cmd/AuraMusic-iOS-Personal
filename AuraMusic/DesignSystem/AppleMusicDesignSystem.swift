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

public struct AuraArtworkView: View {
    public let url: URL?
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public var isPlayingElevated: Bool = false
    public var placeholderSymbol: String = "music.note"

    @State private var loadedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme

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
    }

    public var body: some View {
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

            if let loadedImage {
                Image(uiImage: loadedImage)
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
            loadedImage = await ArtworkCacheManager.shared.image(for: url)
        }
    }
}

// MARK: - Animated Apple Music Fluid Artwork Mesh Background

public struct DynamicArtworkMeshBackground: View {
    public let artworkURL: URL?
    public var isAnimating: Bool = true

    @State private var palette: [Color] = [
        Color(red: 0.98, green: 0.14, blue: 0.23),
        Color(red: 0.42, green: 0.09, blue: 0.38),
        Color(red: 0.12, green: 0.08, blue: 0.22),
        Color(red: 0.06, green: 0.06, blue: 0.10)
    ]
    @State private var phaseShift: Bool = false

    public init(artworkURL: URL?, isAnimating: Bool = true) {
        self.artworkURL = artworkURL
        self.isAnimating = isAnimating
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.08)

                Circle()
                    .fill(palette[0].opacity(0.75))
                    .frame(width: proxy.size.width * 1.15, height: proxy.size.width * 1.15)
                    .offset(
                        x: phaseShift ? -proxy.size.width * 0.25 : proxy.size.width * 0.22,
                        y: phaseShift ? -proxy.size.height * 0.22 : -proxy.size.height * 0.10
                    )

                Circle()
                    .fill(palette[1].opacity(0.70))
                    .frame(width: proxy.size.width * 1.25, height: proxy.size.width * 1.25)
                    .offset(
                        x: phaseShift ? proxy.size.width * 0.28 : -proxy.size.width * 0.18,
                        y: phaseShift ? proxy.size.height * 0.12 : -proxy.size.height * 0.24
                    )

                Circle()
                    .fill(palette[2].opacity(0.75))
                    .frame(width: proxy.size.width * 1.2, height: proxy.size.width * 1.2)
                    .offset(
                        x: phaseShift ? -proxy.size.width * 0.15 : proxy.size.width * 0.18,
                        y: phaseShift ? proxy.size.height * 0.26 : proxy.size.height * 0.18
                    )

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .blur(radius: 58)
            .clipped()
        }
        .ignoresSafeArea()
        .task(id: artworkURL) {
            let newPalette = await ArtworkCacheManager.shared.dominantColors(for: artworkURL)
            withAnimation(.easeInOut(duration: 0.9)) {
                palette = newPalette
            }
        }
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.easeInOut(duration: 9.0).repeatForever(autoreverses: true)) {
                phaseShift.toggle()
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

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: provider.systemIconName)
                .font(.system(size: 9, weight: .bold))
            Text(provider.shortBadgeName)
                .font(.system(size: 9, weight: .bold, design: .rounded))
            if let capability {
                Text("• \(capability.rawValue.uppercased())")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .opacity(0.88)
            }
        }
        .foregroundStyle(provider.badgeColor)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(provider.badgeColor.opacity(0.14))
        )
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
