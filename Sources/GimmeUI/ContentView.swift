import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case updates = "Updates"
    case browse = "Browse"
    case byManager = "By Manager"
    case consolidate = "Consolidate"
    case preferences = "Preferences"
    case activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .installed: return "square.grid.2x2"
        case .updates: return "arrow.up.circle"
        case .browse: return "magnifyingglass"
        case .byManager: return "shippingbox"
        case .consolidate: return "arrow.triangle.merge"
        case .preferences: return "gear"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarSection? = .installed

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .navigationTitle("gimmie")
        } detail: {
            switch selection {
            case .installed:     InstalledView()
            case .updates:       UpdatesView()
            case .browse:        BrowseView()
            case .byManager:     ByManagerView()
            case .consolidate:   ConsolidateView()
            case .preferences:   PreferencesView()
            case .activity:      ActivityView()
            case .none:          Text("Select a section")
            }
        }
    }
}
