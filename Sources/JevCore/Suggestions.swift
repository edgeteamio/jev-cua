import Foundation

/// "What can I say?" (review 2026-09-28, item 3d): example phrases for the app in front, worded
/// the way the labs show people talk. Pure, so the spoken help phrase, the status menu, and the
/// notch's hover hint all read one tested list.
public enum Suggestions {
    /// A query each searchable catalog site answers well, for "search for …" on that site.
    static let siteExamples: [String: String] = [
        "wikipedia": "Norbert Wiener", "youtube": "lofi beats", "github": "swift argument parser", "reddit": "mechanical keyboards",
        "amazon": "usb-c cables", "x_twitter": "swift 6", "hacker_news": "sqlite",
    ]

    public static func phrases(bundleId: String?, pageHost: String?, limit: Int = 4) -> [String] {
        let out: [String]
        switch bundleId {
        case let b? where Config.browserBundleIds.contains(b):
            // On a searchable site other than Google, a bare "search for" stays on that site.
            if let site = Config.site(forHost: pageHost), site.option != Config.defaultSearchSite, let example = siteExamples[site.option] {
                out = ["search for \(example)", "scroll down three times", "go back", "open a new tab"]
            } else {
                out = ["google norbert wiener", "search youtube for lofi beats", "scroll down three times", "go back", "open a new tab"]
            }
        case "com.apple.Notes":
            out = ["create a new note", "make the title say groceries", "type milk and eggs", "undo that"]
        case "com.apple.PhotoBooth":
            out = ["take a picture of me", "open the notes app", "open chrome"]
        default:
            out = ["open chrome", "open the notes app", "google norbert wiener", "take a picture of me"]
        }
        return Array(out.prefix(limit))
    }
}

/// The inverse of a voice action, when a safe one exists (item 3d, "Undo last action"). A page the
/// action navigated to in the current tab goes Back; text it typed or a note it made uses the
/// app's own Edit › Undo. Launches, new tabs, clicks, photos, scrolls, and keys have no safe
/// inverse, so they are never offered.
public enum Undo {
    /// The executor's detail for a navigation that stayed in the front tab (the only kind Back undoes).
    public static let navigatedInPlace = "navigated in the current tab"

    /// `detail` is the executor's account of how the action ran.
    public static func inverse(of action: Action, detail: String) -> Action? {
        switch action {
        case .webSearch, .openSite: return detail == navigatedInPlace ? .goBack : nil
        case .typeText, .newNote: return .menuItem(id: "undo", path: "Edit › Undo")
        default: return nil
        }
    }
}
