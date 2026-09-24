import Foundation

/// Every number and catalog the policy reads. One file to review.
/// Thresholds are starting hypotheses (NEW_COMBINED_PLAN.md 9.1); Phase 1's lab replaces them
/// with tuned values and a comment citing the lab numbers.
public enum Config {
    // MARK: Model

    /// Pinned. `jev-latest` moves on release and the thresholds below are tuned per version.
    public static let model = "jev-1.13.0"
    public static let baseURL = URL(string: "https://api.typesafe.ai")!
    public static let pricePerMillionInputTokensUSD = 0.042   // output tokens are free

    // MARK: Thresholds

    public enum T {
        /// Lab 2026-09-19: non-commands scored at most 0.23 (calibration) and 0.09 (held-out);
        /// the genuine command "dismiss that" scored 0.42. 0.35 sits between them.
        public static let isCommand = 0.35          // Noul gate: addressed to the computer
        public static let intentConfidence = 0.55   // Choice confidence to act at all
        /// Lab 2026-09-19 (calibration, 52 commands): the premature fire "launch photo" (before
        /// "booth") scored 0.65; the genuine early fire "scroll down" (before "a bit") scored 0.69;
        /// other genuine early fires scored >= 0.72. 0.67 separates them with a thin 0.04 margin.
        /// Jev is self-consistent so this holds on these phrases; Phase 3 real-speech runs must
        /// confirm it on new ones.
        public static let complete = 0.67           // Noul gate, bypassed by silence or final
        /// Lab 2026-09-19: requiring the intent to hold across two revisions blocked every early
        /// fire on 3-word commands (the confident revision is the second-to-last one) and never
        /// prevented a wrong fire; the confidence gate caught each transient (e.g. "open x" at
        /// 0.32). Above this confidence a single revision may fire; below it stability is required.
        public static let earlyHighConfidence = 0.85
        public static let targetConfidence = 0.45   // else disambiguate
        public static let targetTopProb = 0.35      // and the winner needs this much mass
        public static let spanConfidence = 0.35     // below this: wait, then search proceeds / type asks
        public static let destructive = 0.50        // above this on a gated action: spoken confirm
        public static let candidateCount = 3        // badges shown when ambiguous
        public static let commandSpanConfidence = 0.50   // below this the whole unconsumed text is consumed
        public static let earlyScrollStableMs = 300      // scroll and searchable-site opens fire early only after the words held still this long
        public static let isCommandAfterConsumed = 0.55  // a remainder after a consumed command must clear this to be a command of its own
        public static let followupConfidence = 0.60      // "supplies_text" needs this much to act on a bare phrase
        public static let placementConfidence = 0.60     // "type_placement" must clear this to replace text instead of inserting
        public static let disambiguateMinProb = 0.08
    }

    // MARK: Timing (ms)

    public static let throttleMs = 150
    public static let repeatGapMs = 120                // between the runs of a counted action ("scroll down three times")
    public static let maxWaitMs = 400
    public static let maxInflight = 1              // one in flight + latest pending
    public static let silenceCompleteMs = 900
    /// With no new words for this long, the transcript counts as silent even if the mic is loud.
    public static let noisyRoomStableMs = 1200
    /// A bare phrase counts as a follow-up to the last action only within this window.
    public static let followupWindowS = 15.0
    public static let payloadSilenceMs = 600
    public static let candidateTtlMs = 8000
    public static let snapshotTtlMs = 1500
    /// Executor settle waits for bringing an app to the front (plan section 11).
    public static let activateWaitMs = 3000
    public static let coldLaunchWaitMs = 12000
    public static let sessionRolloverSeconds = 45.0

    // MARK: Early execution (9.2)

    /// Actions a non-final transcript may fire, and only when the intent held across two
    /// consecutive revisions. Everything else waits for a committed clause.
    public static let earlyExecutionKinds: Set<String> = ["open_app", "open_site", "scroll_up", "scroll_down", "press_escape"]

    /// Intents whose payload is free text; they wait for the final result or payload silence.
    public static let payloadIntents: Set<String> = ["web_search", "type_text", "open_site"]

    // MARK: Catalogs (code owns bundle ids and URLs; Jev only picks the option)

    public struct AppEntry: Sendable {
        public let option: String
        public let name: String
        public let bundleId: String
        public let spoken: String
    }

    public static let apps: [AppEntry] = [
        AppEntry(option: "notes", name: "Notes", bundleId: "com.apple.Notes", spoken: "notes, the notes app, apple notes"),
        AppEntry(option: "chrome", name: "Google Chrome", bundleId: "com.google.Chrome", spoken: "chrome, google chrome, the browser"),
        AppEntry(option: "safari", name: "Safari", bundleId: "com.apple.Safari", spoken: "safari"),
        AppEntry(option: "photo_booth", name: "Photo Booth", bundleId: "com.apple.PhotoBooth", spoken: "photo booth, the camera app"),
        // Photos is on every Mac; in the catalog so "launch photo" holds for "booth" without the
        // machine's installed-app list (the committed lab cache is built without that list).
        AppEntry(option: "photos", name: "Photos", bundleId: "com.apple.Photos", spoken: "photos, the photo library, my pictures"),
        AppEntry(option: "finder", name: "Finder", bundleId: "com.apple.finder", spoken: "finder, the file browser"),
        AppEntry(option: "messages", name: "Messages", bundleId: "com.apple.MobileSMS", spoken: "messages, imessage, texts"),
        AppEntry(option: "mail", name: "Mail", bundleId: "com.apple.mail", spoken: "mail, apple mail, email"),
        AppEntry(option: "calendar", name: "Calendar", bundleId: "com.apple.iCal", spoken: "calendar, ical"),
        AppEntry(option: "music", name: "Music", bundleId: "com.apple.Music", spoken: "music, apple music, itunes"),
        AppEntry(option: "terminal", name: "Terminal", bundleId: "com.apple.Terminal", spoken: "terminal, the shell"),
        AppEntry(option: "system_settings", name: "System Settings", bundleId: "com.apple.systempreferences", spoken: "settings, system settings, preferences, system preferences"),
    ]

    public static func app(option: String) -> AppEntry? { apps.first { $0.option == option } }

    public struct SiteEntry: Sendable {
        public let option: String
        public let description: String
        public let home: String
        /// `%s` is replaced with the URL-encoded query.
        public let search: String?
        /// Search sorted newest first, for "latest" / "newest" / "recent" queries (YouTube's sp=CAI).
        public let newestSearch: String?
        public init(option: String, description: String, home: String, search: String? = nil, newestSearch: String? = nil) {
            self.option = option; self.description = description; self.home = home; self.search = search; self.newestSearch = newestSearch
        }
    }

    public static let sites: [SiteEntry] = [
        SiteEntry(option: "google", description: "Google (google, google it, google search)", home: "https://www.google.com/", search: "https://www.google.com/search?q=%s"),
        SiteEntry(option: "x_twitter", description: "X / Twitter (x, x dot com, twitter)", home: "https://x.com/", search: "https://x.com/search?q=%s"),
        SiteEntry(option: "youtube", description: "YouTube (videos)", home: "https://www.youtube.com/", search: "https://www.youtube.com/results?search_query=%s",
                  newestSearch: "https://www.youtube.com/results?search_query=%s&sp=CAI%253D"),
        SiteEntry(option: "wikipedia", description: "Wikipedia (the encyclopedia)", home: "https://en.wikipedia.org/wiki/Main_Page", search: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteEntry(option: "github", description: "GitHub (code, repositories)", home: "https://github.com/", search: "https://github.com/search?q=%s&type=repositories"),
        SiteEntry(option: "reddit", description: "Reddit", home: "https://www.reddit.com/", search: "https://www.reddit.com/search/?q=%s"),
        SiteEntry(option: "amazon", description: "Amazon (shopping)", home: "https://www.amazon.com/", search: "https://www.amazon.com/s?k=%s"),
        SiteEntry(option: "hacker_news", description: "Hacker News (hn, news.ycombinator.com)", home: "https://news.ycombinator.com/", search: "https://hn.algolia.com/?q=%s"),
    ]

    public static let defaultSearchSite = "google"
    public static func site(option: String) -> SiteEntry? { sites.first { $0.option == option } }

    // MARK: Deny list (enforced in perception before the question, and in policy after the pick)

    public static let denyTerms: [String] = [
        "send", "pay", "buy", "checkout", "place order", "delete", "empty trash", "sign out", "log out", "quit",
    ]

    /// No click or type action inside these apps (plan section 2; macbrow's blocked-app list).
    /// `open_app` may still bring them forward, except System Settings which is never a target.
    public static let denyApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail",                       // messaging
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "io.alacritty", "net.kovidgoyal.kitty",                         // terminals
        "com.apple.systempreferences", "com.apple.keychainaccess",      // system and secrets
        "com.1password.1password", "com.bitwarden.desktop",             // password managers
        "com.apple.ScriptEditor2", "com.apple.Automator",               // scripting
        "com.apple.DiskUtility", "com.apple.ActivityMonitor",           // system tools
        "com.objective-see.lulu.app",                                   // the firewall
    ]

    public static func isDenied(text: String) -> Bool {
        let t = text.lowercased()
        return denyTerms.contains { t.contains($0) }
    }

    /// Menu commands never pressed by voice, beyond `denyTerms`: anything that discards, moves to
    /// the trash, ends a session, or restarts the machine.
    public static let menuDenyTerms: [String] = ["trash", "erase", "reset", "discard", "revert", "shut down", "restart", "log out", "force quit", "remove", "clear history", "clear browsing"]
    public static func isMenuDenied(path: String) -> Bool {
        let t = path.lowercased()
        return isDenied(text: t) || menuDenyTerms.contains { t.contains($0) }
    }
    public static let maxMenusInState = 40

    // MARK: Perception caps

    public static let maxElements = 100
    /// Elements sent in `state` and offered in the target heads per decision; the walk keeps up
    /// to `maxElements` in reading order and the rest is dropped (logged as truncated).
    public static let maxElementsInState = 60
    public static let maxElementTextChars = 60
    public static let maxAdoptedLabelChars = 80
    public static let maxTranscriptChars = 400
    public static let maxOffscreenElements = 120
    public static let walkNodeCap = 4000
    public static let walkTimeCapSeconds = 0.6
}
