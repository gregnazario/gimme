import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case updates = "Updates"
    case browse = "Browse"
    case explore = "Explore"
    case managers = "Package Managers"
    case consolidate = "Consolidate"
    case preferences = "Preferences"
    case activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .installed: return "square.grid.2x2"
        case .updates: return "arrow.up.circle"
        case .browse: return "magnifyingglass"
        case .explore: return "sparkles"
        case .managers: return "shippingbox"
        case .consolidate: return "arrow.triangle.merge"
        case .preferences: return "gear"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $store.sidebarSelection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .navigationTitle("gimme")
        } detail: {
            VStack(spacing: 0) {
                if store.pendingUpdate != nil {
                    UpdateBanner()
                    Divider()
                }
                switch store.sidebarSelection {
                case .installed:     InstalledView()
                case .updates:       UpdatesView()
                case .browse:        BrowseView()
                case .explore:       ExploreView()
                case .managers:      PackageManagersView()
                case .consolidate:   ConsolidateView()
                case .preferences:   PreferencesView()
                case .activity:      ActivityView()
                }
            }
        }
    }
}
