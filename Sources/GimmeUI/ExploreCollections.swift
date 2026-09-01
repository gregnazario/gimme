import Foundation
import GimmeCore

/// Curated starter collections for Explore (spec: 2026-09-01-explore-
/// collections-design). Compile-time data — adding a tool is a one-line diff.
/// Every name is validated against `brew info --json=v2` before it lands
/// here (2026-09-01); a stale entry fails gracefully in DetailSheet.
struct ExploreTool: Identifiable, Hashable {
    let name: String
    let summary: String
    let manager: ManagerID
    var id: String { "\(manager.rawValue):\(name)" }
    /// Bridge into the shared DetailSheet install flow.
    var searchHit: SearchHit {
        SearchHit(name: name, manager: manager, summary: summary, latestVersion: "")
    }
}

struct ExploreCollection: Identifiable, Hashable {
    let name: String
    let blurb: String
    let icon: String        // SF Symbol on the card
    let tools: [ExploreTool]
    var id: String { name }
}

enum ExploreCollections {
    static let all: [ExploreCollection] = [
        ExploreCollection(name: "CLI Essentials", blurb: "The terminal upgrades nearly everyone keeps.", icon: "terminal", tools: [
            ExploreTool(name: "fzf", summary: "Fuzzy finder for shell history, files, and anything", manager: .homebrew),
            ExploreTool(name: "ripgrep", summary: "Blazing-fast search that respects .gitignore", manager: .homebrew),
            ExploreTool(name: "bat", summary: "cat with syntax highlighting and a git gutter", manager: .homebrew),
            ExploreTool(name: "fd", summary: "Simple, fast alternative to find", manager: .homebrew),
            ExploreTool(name: "eza", summary: "Modern ls replacement with colors and icons", manager: .homebrew),
            ExploreTool(name: "zoxide", summary: "Smarter cd that learns your habits", manager: .homebrew),
            ExploreTool(name: "htop", summary: "Interactive process viewer", manager: .homebrew),
            ExploreTool(name: "dust", summary: "Disk usage analyzer with a treemap view", manager: .homebrew),
            ExploreTool(name: "starship", summary: "Fast, customizable prompt for any shell", manager: .homebrew),
            ExploreTool(name: "tldr", summary: "Community cheat sheets for every command", manager: .homebrew),
        ]),
        ExploreCollection(name: "JSON & Data", blurb: "Query, reshape, and move data from the shell.", icon: "curlybraces", tools: [
            ExploreTool(name: "jq", summary: "The classic command-line JSON processor", manager: .homebrew),
            ExploreTool(name: "yq", summary: "jq-style queries for YAML, XML, and TOML", manager: .homebrew),
            ExploreTool(name: "fx", summary: "Interactive JSON viewer and terminal debugger", manager: .homebrew),
            ExploreTool(name: "duckdb", summary: "In-process SQL database that queries files", manager: .homebrew),
            ExploreTool(name: "xh", summary: "Friendly, fast HTTPie-style requests in one binary", manager: .homebrew),
            ExploreTool(name: "httpie", summary: "Human-friendly HTTP client for API testing", manager: .homebrew),
            ExploreTool(name: "aria2", summary: "Resumable, parallel multi-protocol downloads", manager: .homebrew),
            ExploreTool(name: "visidata", summary: "Spreadsheet-like terminal UI for tabular data", manager: .homebrew),
        ]),
        ExploreCollection(name: "Git & GitHub", blurb: "See more, type less, diff smarter.", icon: "arrow.triangle.branch", tools: [
            ExploreTool(name: "gh", summary: "GitHub CLI — PRs, issues, and releases", manager: .homebrew),
            ExploreTool(name: "lazygit", summary: "Terminal UI for git you can actually learn", manager: .homebrew),
            ExploreTool(name: "git-delta", summary: "Syntax-highlighting pager for git diffs", manager: .homebrew),
            ExploreTool(name: "tig", summary: "Text-mode interface for git history", manager: .homebrew),
            ExploreTool(name: "difftastic", summary: "Structural diff that understands syntax", manager: .homebrew),
            ExploreTool(name: "git-lfs", summary: "Large file support for git repos", manager: .homebrew),
            ExploreTool(name: "glab", summary: "GitLab CLI — the gh equivalent for GitLab", manager: .homebrew),
            ExploreTool(name: "gitui", summary: "Blazing-fast terminal UI for git", manager: .homebrew),
        ]),
        ExploreCollection(name: "GUI Apps", blurb: "Hand-picked Mac apps, installed by brew.", icon: "macwindow", tools: [
            ExploreTool(name: "rectangle", summary: "Window snapping and keyboard tiling (GUI app)", manager: .homebrew),
            ExploreTool(name: "raycast", summary: "Launcher and command palette (GUI app)", manager: .homebrew),
            ExploreTool(name: "iterm2", summary: "The macOS terminal, supercharged (GUI app)", manager: .homebrew),
            ExploreTool(name: "stats", summary: "Menu-bar system monitor (GUI app)", manager: .homebrew),
            ExploreTool(name: "appcleaner", summary: "Thorough app uninstaller (GUI app)", manager: .homebrew),
            ExploreTool(name: "keka", summary: "Archive extractor and compressor (GUI app)", manager: .homebrew),
            ExploreTool(name: "maccy", summary: "Clipboard history manager (GUI app)", manager: .homebrew),
            ExploreTool(name: "meetingbar", summary: "Menu-bar calendar for your next meeting (GUI app)", manager: .homebrew),
        ]),
        ExploreCollection(name: "Documents & Media", blurb: "Convert, compress, and transcode anything.", icon: "doc.richtext", tools: [
            ExploreTool(name: "ffmpeg", summary: "Convert, stream, and mangle audio/video", manager: .homebrew),
            ExploreTool(name: "imagemagick", summary: "Create, edit, and convert images from the CLI", manager: .homebrew),
            ExploreTool(name: "pandoc", summary: "Convert documents between markup formats", manager: .homebrew),
            ExploreTool(name: "yt-dlp", summary: "Download video and audio from the web", manager: .homebrew),
            ExploreTool(name: "poppler", summary: "PDF utilities — pdftotext, pdftoppm, and friends", manager: .homebrew),
            ExploreTool(name: "sevenzip", summary: "7-Zip archiver with high compression ratios", manager: .homebrew),
            ExploreTool(name: "mkvtoolnix", summary: "Inspect and remux Matroska files", manager: .homebrew),
            ExploreTool(name: "handbrake", summary: "Open-source video transcoder (GUI app)", manager: .homebrew),
        ]),
    ]
}
