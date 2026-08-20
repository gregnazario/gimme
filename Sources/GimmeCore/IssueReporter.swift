import Foundation

/// Builds a prefilled GitHub new-issue URL for the "Report an Issue" flow
/// (GUI Help menu → sheet → browser). The query-param prefill means the app
/// needs no GitHub credentials: the user reviews and submits the issue.
public enum IssueReporter {
    public static let repoURL = URL(string: "https://github.com/gregnazario/gimme")!

    /// Keep the final URL comfortably under common server/browser ceilings
    /// (~8k). The auto-collected context is the only unbounded part, so it
    /// alone is truncated — keeping the most recent entries.
    private static let maxContextCharacters = 4_000

    public static func issueURL(title: String, happened: String, expected: String, context: String) -> URL? {
        var comps = URLComponents(url: repoURL.appendingPathComponent("issues/new"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body(happened: happened, expected: expected, context: context))
        ]
        return comps.url
    }

    /// The issue body mirrors the bug_report.md template's sections so
    /// button-created issues read like template-created ones.
    private static func body(happened: String, expected: String, context: String) -> String {
        """
        ### What happened

        \(happened.isEmpty ? "_(typed in the app)_" : happened)

        ### What did you expect?

        \(expected.isEmpty ? "_(typed in the app)_" : expected)

        <details><summary>Context (auto-collected by gimme)</summary>

        \(truncate(context))

        </details>
        """
    }

    /// Keep the tail of the context — the newest entries are the relevant
    /// ones for diagnosing what just happened.
    private static func truncate(_ context: String) -> String {
        guard context.count > maxContextCharacters else { return context }
        return "…(earlier entries truncated)\n" + context.suffix(maxContextCharacters)
    }
}
