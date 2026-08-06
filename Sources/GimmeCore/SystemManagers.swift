import Foundation

/// Detects tools installed by OTHER package managers on the system (Homebrew,
/// mise/asdf, MacPorts, Nix, cargo, go, npm, pipx). Read-only — gimme never
/// modifies these, just shows them so the user has a complete picture.
public enum SystemManagers {
    public struct SystemTool: Identifiable, Hashable {
        public let id = UUID()
        public let name: String
        public let version: String
        public let manager: Manager
        public let path: String
    }

    public enum Manager: String, CaseIterable, Identifiable {
        case gimme = "gimme"
        case homebrew = "brew"
        case mise = "mise"
        case asdf = "asdf"
        case macports = "port"
        case nix = "nix"
        case cargo = "cargo"
        case npm = "npm"
        case pipx = "pipx"
        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .gimme: return "star.fill"
            case .homebrew: return "mug.fill"
            case .mise: return "hammer.fill"
            case .asdf: return "wrench.and.screwdriver.fill"
            case .macports: return "ferry.fill"
            case .nix: return "snowflake"
            case .cargo: return "shippingbox.fill"
            case .npm: return "scope"
            case .pipx: return "checkerboard.shield"
            }
        }
        public var displayName: String {
            switch self {
            case .gimme: return "gimme"
            case .homebrew: return "Homebrew"
            case .mise: return "mise"
            case .asdf: return "asdf"
            case .macports: return "MacPorts"
            case .nix: return "Nix"
            case .cargo: return "Cargo"
            case .npm: return "npm"
            case .pipx: return "pipx"
            }
        }
    }

    /// Detect which package managers are installed on this system.
    public static func detectedManagers() -> [Manager] {
        var found: [Manager] = [.gimme]
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        // Homebrew
        if fm.fileExists(atPath: "/opt/homebrew/bin/brew") || fm.fileExists(atPath: "/usr/local/bin/brew") {
            found.append(.homebrew)
        }
        // mise
        if fm.fileExists(atPath: "\(home)/.local/share/mise/installs") || fm.fileExists(atPath: "\(env["MISE_DATA_DIR"] ?? "")/installs") {
            found.append(.mise)
        }
        // asdf
        if fm.fileExists(atPath: "\(home)/.asdf/installs") {
            found.append(.asdf)
        }
        // MacPorts
        if fm.fileExists(atPath: "/opt/local/bin/port") {
            found.append(.macports)
        }
        // Nix
        if fm.fileExists(atPath: "/nix/store") || fm.fileExists(atPath: "/run/current-system/sw/bin") {
            found.append(.nix)
        }
        // Cargo
        if fm.fileExists(atPath: "\(home)/.cargo/bin") {
            found.append(.cargo)
        }
        // npm global
        if fm.fileExists(atPath: "\(home)/.npm-global/bin") || fm.fileExists(atPath: "/usr/local/lib/node_modules") {
            found.append(.npm)
        }
        // pipx
        if fm.fileExists(atPath: "\(home)/.local/pipx") {
            found.append(.pipx)
        }
        return found
    }

    /// Scan all detected package managers for installed tools. Returns a flat list.
    /// gimme's own tools are passed in separately (from the cellar) to avoid
    /// re-scanning.
    public static func scanAllTools(gimmeTools: [(name: String, version: String)]) -> [SystemTool] {
        var tools: [SystemTool] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        // gimme
        for t in gimmeTools {
            tools.append(SystemTool(name: t.name, version: t.version, manager: .gimme,
                                    path: "\(home)/.gimme/bin/\(t.name)"))
        }

        // Homebrew (Cellar + Caskroom)
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellar = "\(prefix)/Cellar"
            if fm.fileExists(atPath: cellar),
               let tools0 = try? fm.contentsOfDirectory(atPath: cellar) {
                for name in tools0.sorted() {
                    let toolDir = "\(cellar)/\(name)"
                    if let versions = try? fm.contentsOfDirectory(atPath: toolDir),
                       let ver = versions.sorted().last {
                        tools.append(SystemTool(name: name, version: ver, manager: .homebrew, path: "\(toolDir)/\(ver)"))
                    }
                }
            }
            let caskroom = "\(prefix)/Caskroom"
            if fm.fileExists(atPath: caskroom),
               let apps = try? fm.contentsOfDirectory(atPath: caskroom) {
                for name in apps.sorted() {
                    let appDir = "\(caskroom)/\(name)"
                    if let versions = try? fm.contentsOfDirectory(atPath: appDir),
                       let ver = versions.sorted().last {
                        tools.append(SystemTool(name: name, version: ver, manager: .homebrew, path: appDir))
                    }
                }
            }
        }

        // mise
        let miseInstalls = env["MISE_DATA_DIR"].map { "\($0)/installs" }
            ?? "\(home)/.local/share/mise/installs"
        if fm.fileExists(atPath: miseInstalls),
           let tools0 = try? fm.contentsOfDirectory(atPath: miseInstalls) {
            for name in tools0.sorted() where name != ".DS_Store" {
                let toolDir = "\(miseInstalls)/\(name)"
                if let versions = try? fm.contentsOfDirectory(atPath: toolDir) {
                    let filtered = versions.filter { $0 != ".DS_Store" && $0 != "latest" }
                    let ver = filtered.sorted().last ?? "latest"
                    tools.append(SystemTool(name: name, version: ver, manager: .mise, path: toolDir))
                }
            }
        }

        // asdf
        let asdfInstalls = "\(home)/.asdf/installs"
        if fm.fileExists(atPath: asdfInstalls),
           let tools0 = try? fm.contentsOfDirectory(atPath: asdfInstalls) {
            for name in tools0.sorted() where name != ".DS_Store" {
                let toolDir = "\(asdfInstalls)/\(name)"
                if let versions = try? fm.contentsOfDirectory(atPath: toolDir) {
                    let ver = versions.filter { $0 != ".DS_Store" }.sorted().last ?? "unknown"
                    tools.append(SystemTool(name: name, version: ver, manager: .asdf, path: toolDir))
                }
            }
        }

        // Cargo
        let cargoBin = "\(home)/.cargo/bin"
        if fm.fileExists(atPath: cargoBin),
           let bins = try? fm.contentsOfDirectory(atPath: cargoBin) {
            for bin in bins.sorted() where !bin.hasPrefix(".") && bin != ".cargo" {
                tools.append(SystemTool(name: bin, version: "—", manager: .cargo, path: "\(cargoBin)/\(bin)"))
            }
        }

        // MacPorts
        let portDir = "/opt/local/var/macports/registry/portfiles"
        if fm.fileExists(atPath: portDir),
           let cats = try? fm.contentsOfDirectory(atPath: portDir) {
            for cat in cats {
                let catDir = "\(portDir)/\(cat)"
                if let ports = try? fm.contentsOfDirectory(atPath: catDir) {
                    for port in ports.sorted() {
                        tools.append(SystemTool(name: port, version: "—", manager: .macports, path: catDir))
                    }
                }
            }
        }

        // Nix
        let nixProfile = "\(home)/.nix-profile/bin"
        if fm.fileExists(atPath: nixProfile),
           let bins = try? fm.contentsOfDirectory(atPath: nixProfile) {
            for bin in bins.sorted() where !bin.hasPrefix(".") {
                tools.append(SystemTool(name: bin, version: "—", manager: .nix, path: "\(nixProfile)/\(bin)"))
            }
        }

        return tools
    }
}
