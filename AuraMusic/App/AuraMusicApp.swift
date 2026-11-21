import SwiftData
import SwiftUI

@main
public struct AuraMusicApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var player = UniversalAudioPlayerEngine.shared
    @StateObject private var downloadManager = OfflineDownloadManager.shared

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootAppleMusicTabView()
                .modelContainer(persistence.container)
                .tint(AuraTheme.accentPink)
        }
    }
}

public enum AppleMusicRootTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case browse = "New"
    case radio = "Radio"
    case library = "Library"
    case search = "Search"

    public var id: String { rawValue }

    public var systemSymbolName: String {
        switch self {
        case .home: return "house.fill"
        case .browse: return "square.grid.2x2.fill"
        case .radio: return "dot.radiowaves.left.and.right"
        case .library: return "play.square.stack.fill"
        case .search: return "magnifyingglass"
        }
    }
}

public struct RootAppleMusicTabView: View {
    @ObservedObject var player: UniversalAudioPlayerEngine = .shared
    @State private var selectedTab: AppleMusicRootTab = .home

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                ListenNowTabView()
                    .tabItem {
                        Label(AppleMusicRootTab.home.rawValue, systemImage: AppleMusicRootTab.home.systemSymbolName)
                    }
                    .tag(AppleMusicRootTab.home)

                BrowseTabView()
                    .tabItem {
                        Label(AppleMusicRootTab.browse.rawValue, systemImage: AppleMusicRootTab.browse.systemSymbolName)
                    }
                    .tag(AppleMusicRootTab.browse)

                RadioTabView()
                    .tabItem {
                        Label(AppleMusicRootTab.radio.rawValue, systemImage: AppleMusicRootTab.radio.systemSymbolName)
                    }
                    .tag(AppleMusicRootTab.radio)

                LibraryTabView()
                    .tabItem {
                        Label(AppleMusicRootTab.library.rawValue, systemImage: AppleMusicRootTab.library.systemSymbolName)
                    }
                    .tag(AppleMusicRootTab.library)

                UnifiedSearchView()
                    .tabItem {
                        Label(AppleMusicRootTab.search.rawValue, systemImage: AppleMusicRootTab.search.systemSymbolName)
                    }
                    .tag(AppleMusicRootTab.search)
            }
            .tint(AuraTheme.accentPink)

            AppleMusicPlayerOverlayView()
        }
    }
}
