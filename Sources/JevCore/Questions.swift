import Foundation

/// The question catalog (plan section 7.1). All questions go in one request. Question ids are
/// not sent to the model, so every instruction is a complete question that names the state
/// field it reads with backticks. Criteria use the contrastive {what, not_for, examples} shape
/// (ported from moritzkremb/jev-voice-browser src/constants.js): Jev reads literally, and
/// overlapping options read as doubt.
public enum Questions {
    public static let version = "q25"  // q25: duplicated labels carry their row mates; q24: followup repeats_action (again/once more re-runs the last action); q23: menu_item intent and menu_target head; q22: type_placement head (replace a title or a field vs insert); q21: "with ... as the body" clauses; q20: app mentions count; q19: goal-mode span and field heads read history; q18: title clauses; q17: clause examples for verb-less and switch-back steps; q16: two-phase goal steps; q15: clauses in goal state, next_action reasons from them; q14: goal_achieved needs history evidence; q13: goal-mode heads, reobserve tied to history; q12: element container in descriptions; q11: questions count as web searches; q10: followup head; q9: site+query is web_search; q8: text_span examples; q7: command_span examples and joiner rule; q6: elements as compact strings, 60 cap; q5: click_target/type_target/offscreen_target heads; q4: "first command" scoping; q3: command_span head; q2: is_command examples widened (lab 2026-09-19)   // bump when any wording changes; part of the lab cache key via the request hash

    // MARK: Intent

    public static let intentOptions: [String] = [
        "open_app", "new_note", "web_search", "open_site", "take_photo", "type_text", "click_element",
        "press_enter", "press_escape", "scroll_down", "scroll_up", "go_back", "menu_item", "confirm", "cancel", "none",
    ]

    static func option(_ what: String, notFor: String, examples: [String]) -> JSONValue {
        ["what": .string(what), "not_for": .string(notFor), "examples": .array(examples.map(JSONValue.string))]
    }

    public static let intentCriteria: [String: JSONValue] = [
        "open_app": option("Open, launch, switch to, or go to a named Mac application",
                           notFor: "Opening a website; creating a note",
                           examples: ["open the notes app", "open chrome", "switch to finder", "launch photo booth"]),
        "new_note": option("Create a new note in Apple Notes",
                           notFor: "Typing into an existing note; opening Notes alone",
                           examples: ["create a new note", "make a new note", "new note"]),
        "web_search": option("Search the web or a named site for a topic or phrase, including a site name followed by what to look up there, and any question the user wants answered from the web (who, what, when, where, how, is)",
                             notFor: "Opening a site's homepage with nothing to look up; typing into a field that is not a search",
                             examples: ["google search norbert wiener", "search for alan turing", "look up typesafe jev", "search youtube for lofi",
                                        "open wikipedia mark zuckerberg", "wikipedia alan turing", "youtube lofi beats",
                                        "when do the vikings play next", "how tall is the eiffel tower", "what time is it in tokyo", "pull up the latest alex hormozi youtube videos", "find me a good pasta recipe"]),
        "open_site": option("Open a specific website's home page by name or spoken domain in the browser, with nothing to look up there",
                            notFor: "A site name followed by a topic or phrase to look up (that is web_search); opening a Mac app",
                            examples: ["open x dot com", "go to wikipedia", "take me to github"]),
        "take_photo": option("Take a picture with the camera in Photo Booth",
                             notFor: "Opening Photo Booth without taking a picture",
                             examples: ["take a picture of me", "take a photo", "snap a picture"]),
        "type_text": option("Type or enter specific text into the focused field, note, or document, including setting a note's title",
                            notFor: "Running a web search; pressing enter alone",
                            examples: ["make the title say hello", "type hello world", "write good morning", "call it groceries"]),
        "click_element": option("Click, press, open, select, or choose a control that is on screen in `elements`",
                                notFor: "Opening an app or site by name; typing",
                                examples: ["click the first result", "press take photo", "open the second link", "select the dark option"]),
        "press_enter": option("Press Return to submit or confirm the focused field",
                              notFor: "Typing text; clicking a named button",
                              examples: ["press enter", "hit return", "submit"]),
        "press_escape": option("Press Escape to dismiss a dialog, popup, or menu",
                               notFor: "Cancelling a pending confirmation",
                               examples: ["press escape", "dismiss that", "close the popup"]),
        "scroll_down": option("Scroll or move down in the front window",
                              notFor: "Scrolling up; going back",
                              examples: ["scroll down", "scroll down a bit", "go to the bottom", "page down"]),
        "scroll_up": option("Scroll or move up",
                            notFor: "Scrolling down",
                            examples: ["scroll up", "back to the top"]),
        "go_back": option("Go back to the previous page in the browser",
                          notFor: "Scrolling up; closing a window",
                          examples: ["go back", "back", "previous page"]),
        "menu_item": option("Run a command from the front app's menu bar by its name, one of the `menus` listed, when no other option covers it: save, close the window or tab, new window or tab, undo, redo, select all, find, reload, print, zoom, show or hide a panel",
                            notFor: "Creating a note (new_note); opening an app or site; clicking something on screen; going back in the browser; quitting or deleting",
                            examples: ["save", "close the window", "open a new tab", "undo that", "select all", "zoom in", "reload the page", "show the sidebar"]),
        "confirm": option("Approve the action the assistant asked to confirm (`pending_confirmation` is set)",
                          notFor: "New commands",
                          examples: ["confirm", "yes do it", "go ahead"]),
        "cancel": option("Cancel, never mind, or stop the pending action or the assistant",
                         notFor: "Going back in the browser",
                         examples: ["cancel", "never mind", "stop"]),
        "none": option("Not a command to the computer, or nothing recognizable yet (fragment, filler, talking to a person, a negated command)",
                       notFor: "Anything that clearly matches another option",
                       examples: ["um", "okay so", "what do you think", "open the", "don't open notes"]),
    ]

    public static let intentInstructions: JSONValue = [
        "question": "Which Mac action does the user ask for in `transcript`?",
        "focus": "Judge the words said so far. If the sentence is unfinished, pick the action the words already commit to; if no action is recognizable yet pick none. If `transcript` contains more than one command, answer for the first one only; later commands are handled after it. `frontmost_app` and `elements` describe what is on screen.",
    ]

    // MARK: App

    public static let appNotStated = "not_stated"

    /// Catalog entries plus installed apps (macbrow's dynamic `apps`), running ones annotated.
    public static func appCriteria(installedApps: [String] = [], runningApps: Set<String> = []) -> [String: JSONValue] {
        var c: [String: JSONValue] = [:]
        for a in Config.apps { c[a.option] = .string(a.spoken) }
        let catalogNames = Set(Config.apps.map { $0.name.lowercased() })
        var extra = installedApps.filter { !catalogNames.contains($0.lowercased()) }
        extra.sort { (runningApps.contains($0) ? 0 : 1, $0) < (runningApps.contains($1) ? 0 : 1, $1) }
        for name in extra.prefix(180) {
            c[Self.optionId(forApp: name)] = .string(runningApps.contains(name) ? "\(name) (running)" : name)
        }
        c[appNotStated] = "No application is named in `transcript`"
        return c
    }

    /// Installed apps worth offering for this transcript: those whose name shares a word (three
    /// letters or more, prefix match) with it. Keeps the head small; "open blender" still resolves.
    public static func relevantInstalledApps(_ installed: [String], transcript: String, cap: Int = 20) -> [String] {
        let words = Set(Transcript.normalize(transcript).split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        let catalogNames = Set(Config.apps.map { $0.name.lowercased() })
        var out: [String] = []
        for name in installed where !catalogNames.contains(name.lowercased()) {
            let nameWords = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if nameWords.contains(where: { nw in words.contains(where: { w in nw.hasPrefix(w) || w.hasPrefix(nw) && nw.count >= 3 }) }) { out.append(name) }
            if out.count >= cap { break }
        }
        return out
    }

    public static func optionId(forApp name: String) -> String {
        "app:" + name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    public static let appInstructions: JSONValue = [
        "question": "Which Mac application does the user name in the first command of `transcript`?",
        "focus": "Only what is explicitly said; any mention counts, including 'in chrome', 'using notes', or 'switch back to notes'. Pick not_stated if no app is named.",
    ]

    // MARK: Site

    public static let siteNotStated = "not_stated"

    public static func siteCriteria() -> [String: JSONValue] {
        var c: [String: JSONValue] = [:]
        for s in Config.sites { c[s.option] = .string(s.description) }
        c["the_web"] = "A general web search with no site named (search the web, look it up online)"
        c["other_named_site"] = "A domain or brand not listed, spoken in `transcript`"
        c[siteNotStated] = "No website or search engine is named in `transcript`"
        return c
    }

    public static let siteInstructions: JSONValue = [
        "question": "Which website or search engine does the user name in the first command of `transcript`?",
        "focus": "Only what is explicitly said.",
    ]

    // MARK: Gates

    public static let completeQuestion = Question.noul(
        [
            "question": "Has the user finished saying the command in `transcript`, so it can be executed now without waiting for more words?",
            "focus": "Speech arrives word by word. A command is complete when its verb and any required object are present: an app for open, a query for search, an element for click, text for type.",
        ],
        true: ["what": "Complete, actionable command", "examples": ["open the notes app", "take a picture", "google search norbert wiener", "click the first result"]],
        false: ["what": "Cut off before the required object; more words are clearly coming", "examples": ["open the", "search for", "click the", "make the title say", "google search"]]
    )

    public static let isCommandQuestion = Question.noul(
        [
            "question": "Is `transcript` an instruction or a request addressed to this computer (open, search, click, type, scroll, take a photo, confirm, cancel, or a question the user wants looked up)?",
            "focus": "A direct question the user wants answered from the web counts (when does a team play next, how tall is a landmark, what is the weather). Chit-chat, narration, talking to another person, musing aloud (I wonder, I was going to), reading aloud, a negated instruction, or a stray fragment is not a command.",
        ],
        true: ["what": "An imperative or a direct question aimed at the computer, however short or casual",
               "examples": ["open chrome", "take a picture of me", "scroll down a bit", "dismiss that", "call it groceries", "go ahead",
                            "when do the vikings play next", "how tall is the eiffel tower", "what's the weather like tomorrow", "pull up the latest alex hormozi youtube videos"]],
        false: ["what": "Not directed at the computer", "examples": ["I think we should get lunch", "so this is the demo", "what did you say", "don't open notes", "the notes app is nice",
                                                                       "I wonder when the vikings play next", "my brother loves alex hormozi videos"]]
    )

    public static let destructiveQuestion = Question.noul(
        [
            "question": "Would carrying out the action in `transcript` on the current screen send a message, send an email, post publicly, pay, buy, delete, sign out, quit an app, or otherwise do something hard to undo?",
            "focus": "Opening apps and sites, searching, scrolling, typing into a note, and taking a photo are not destructive.",
        ],
        true: ["what": "Irreversible side effect", "examples": ["click send", "press delete", "click buy now", "quit the app"]],
        false: ["what": "Reversible or read-only", "examples": ["open notes", "take a picture", "type hello", "scroll down"]]
    )

    public static let scrollAmountQuestion = Question.score(
        [
            "question": "How far does the user want to scroll according to `transcript`?",
            "focus": "Only relevant when scrolling; default is one screen when nothing is specified.",
        ],
        ["A little: a few lines (a bit, slightly, a little)", "One screen, or no amount specified", "All the way to the end (top or bottom)"]
    )

    // MARK: Spans

    public static let spanNone = "none"

    public static func textSpanQuestion(_ spans: [SpanCandidate], goalMode: Bool = false) -> Question {
        var c: [String: JSONValue] = [:]
        for s in spans { c[s.text] = .null }
        c[spanNone] = "Nothing should be typed or searched, or the text is not among the options"
        var focus = "Choose the span that contains only the payload, without the command words that introduce it (type, search for, google, look up, make the title say, call it). Pick none if nothing should be typed or searched."
        if goalMode { focus += " `transcript` may hold several values for several fields (first name Ada and last name Lovelace): `history` lists values already typed; pick the next value not yet typed, on its own." }
        return .choice([
            "question": "Which option is exactly the text the user wants typed or searched in the first command of `transcript`? Options are verbatim candidate spans.",
            "focus": .string(focus),
            "examples": [["google mark zuckerberg", "mark zuckerberg"], ["search for alan turing please", "alan turing"], ["make the title say hello", "hello"], ["type hello world", "hello world"],
                         ["fill in first name Ada and last name Lovelace (history: type_text Ada verified)", "Lovelace"]],
        ], c)
    }

    /// Whether the spoken text replaces what the field holds or is added to it. Asked with
    /// `text_span`; code applies it only to a `type_text` and only above `placementConfidence`,
    /// so an unsure answer falls back to inserting (undoable by the user, never a lost title).
    public static func typePlacementQuestion() -> Question {
        .choice([
            "question": "Where does the text of the first command in `transcript` go, relative to what `focused_field` already holds?",
            "focus": "Replacing means the old text goes away. Pick insert when the command only says to type, write, enter, add, or put text, or says nothing about existing text. A note's title is its first line.",
            "examples": [["type hello", "insert"], ["write good morning", "insert"], ["add milk and eggs", "insert"], ["with milk and eggs as the body", "insert"],
                         ["change the title to groceries", "replace_title"], ["rename the note shopping list", "replace_title"], ["make the title say hello", "replace_title"],
                         ["set the title to weekly plan", "replace_title"], ["replace the text with good morning", "replace_all"], ["change the search to alan turing", "replace_all"],
                         ["clear it and type hello", "replace_all"]],
        ], [
            "insert": "Add the text at the cursor, after or among what is there",
            "replace_title": "Replace the field's first line, a note's title, with the text: change, rename, set, or edit the title; make the title say; call it",
            "replace_all": "Replace everything the field holds with the text: change, replace, or set the text, the field, or the value",
        ])
    }

    public static func urlSpanQuestion(_ spans: [SpanCandidate]) -> Question {
        var c: [String: JSONValue] = [:]
        for s in spans { c[s.text] = .null }
        c[spanNone] = "No web address is mentioned"
        return .choice([
            "question": "Which option is the web address (domain) the user wants to open, as spoken in `transcript`?",
            "focus": "Pick none if no address is mentioned.",
        ], c)
    }

    // MARK: Command span

    public static let commandSpanNone = "none"

    /// Word prefixes of the unconsumed transcript. Jev picks the one that ends exactly where the
    /// command being executed ends, so a revision carrying two commands ("open the notes then
    /// scroll down") consumes only the first and the session re-decides on the rest.
    public static func commandPrefixes(_ raw: String, cap: Int = 32) -> [String] {
        let tokens = Transcript.tokens(raw)
        guard tokens.count >= 2 else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for n in 1...min(tokens.count, cap) {
            let p = tokens[0..<n].joined(separator: " ")
            if seen.insert(p.lowercased()).inserted { out.append(p) }
        }
        return out
    }

    public static func commandSpanQuestion(_ prefixes: [String]) -> Question {
        var c: [String: JSONValue] = [:]
        for p in prefixes { c[p] = .null }
        c[commandSpanNone] = "There is no command in `transcript`"
        return .choice([
            "question": "Which option is the shortest prefix of `transcript` that contains the whole of the first command the user gives, ending right after that command's last word? Options are prefixes of `transcript`.",
            "focus": "If the transcript holds one command, the answer is the prefix ending at that command's last word (usually the whole transcript). If it holds two commands joined by words like 'and', 'then', 'and then', 'after that', stop at the end of the first command, before the joining word. Pick none if there is no command.",
            "examples": [
                ["open the notes app and create a new note", "open the notes app"],
                ["open chrome then scroll down", "open chrome"],
                ["google search norbert wiener", "google search norbert wiener"],
                ["make the title say hello and goodbye", "make the title say hello and goodbye"],
            ],
        ], c)
    }

    // MARK: Goal mode (Phase 6, plan section 7 and 12)

    public static let nextActionReobserve = "reobserve"
    public static let nextActionAbstain = "abstain"
    public static let nextActionOptions: [String] = intentOptions.filter { !["confirm", "cancel", "none"].contains($0) } + [nextActionReobserve, nextActionAbstain]

    public static let goalAchievedQuestion = Question.noul(
        ["question": "Is every part of `subgoal` (within `goal`) already achieved, judging only from `history` (actions the computer has verified) and the observed state (`frontmost_app`, `focused_field`, `elements`)?",
         "focus": "Each action the subgoal names (open, create, search, type, click) must show as a verified entry in `history` or as its visible result. An app being frontmost does not achieve 'create a new note' or 'search for X'; a note with old text in it is not a new note. When `history` is empty, only a goal that asks for nothing beyond what is already on screen is achieved.",
         "examples": [
            ["subgoal 'open notes and create a new note'; history ['open_app Notes: verified']; focused_field textarea with text", "false: no note was created"],
            ["subgoal 'open notes and create a new note'; history ['open_app Notes: verified', 'new_note: verified (note list 12 -> 13 rows)']", "true"],
            ["subgoal 'open chrome'; frontmost_app Google Chrome; history []", "true: already in front"],
            ["subgoal 'google search cats'; frontmost_app Google Chrome; history []", "false: no search yet"],
            ["subgoal 'open photo booth and take a picture'; history ['open_app Photo Booth: verified', 'take_photo: verified (capture started)']", "true: every clause verified"],
            ["subgoal 'search google for norbert wiener then open the wikipedia result'; history ['web_search google: verified', 'click_element e12: verified (en.wikipedia.org)']; page_host en.wikipedia.org", "true"],
         ]],
        true: ["what": "Every part of the subgoal is done, with evidence"],
        false: ["what": "At least one part has no evidence yet"]
    )

    public static let blockedQuestion = Question.noul(
        ["question": "Is progress on `goal` blocked by a login wall, a permission or consent prompt, an error dialog, a paywall, or information that is not on this screen and cannot be reached by the available actions?",
         "focus": "A blank or loading page is not blocked; a missing app is not blocked (it can be opened)."],
        true: ["what": "Blocked: the user has to intervene"],
        false: ["what": "Not blocked"]
    )

    public static let needsReobserveQuestion = Question.noul(
        ["question": "Is the observed state stale for deciding the next step: does the last entry of `history` describe an action whose effect is not yet visible in `frontmost_app`, `focused_field`, or `elements` (a page still loading, an app not yet in front), or do two entries of `elements` fit the target equally?",
         "focus": "With an empty `history` the observation is fresh: answer no. When the last action is verified and its effect shows, answer no. Answer yes only for a visible mismatch or a genuine tie."],
        true: ["what": "Stale or ambiguous: observe again before acting"],
        false: ["what": "Fresh enough to act on"]
    )

    public static let nextActionInstructions: JSONValue = [
        "question": "Which single next action carries out the first clause of `clauses` that `history` does not yet show as verified, from the observed state?",
        "focus": "`clauses` are the goal's steps in order; `history` lists actions already verified. Pick the action for the earliest clause still to do, one step at a time. `elements` lists what is clickable or typeable on this screen and `page_host` says which site is open. Pick reobserve only when the screen must be re-read first; abstain only when no available action can carry out that clause or the user must act.",
        "examples": [
            ["clauses ['type Ada in the first name field', 'Lovelace in the last name field']; history ['type_text Ada: verified']", "type_text"],
            ["clauses ['open chrome', 'switch back to notes', 'type hello there']; history ['open_app Google Chrome: verified', 'open_app Notes: verified']; frontmost_app Notes", "type_text"],
            ["clauses ['open chrome', 'search google for norbert wiener', 'open the wikipedia result']; history ['open_app Google Chrome: verified']; page_host en.wikipedia.org", "web_search"],
            ["clauses ['open chrome', 'search google for norbert wiener', 'open the wikipedia result']; history ['open_app Google Chrome: verified', 'web_search google: verified']; elements include link 'Norbert Wiener - Wikipedia'", "click_element"],
            ["clauses ['open photo booth', 'take a picture']; history ['open_app Photo Booth: verified']", "take_photo"],
        ],
    ]

    public static var nextActionCriteria: [String: JSONValue] {
        var c = intentCriteria.filter { !["confirm", "cancel", "none"].contains($0.key) }
        c[nextActionReobserve] = option("Look at the screen again before deciding", notFor: "When the state is already clear", examples: [])
        c[nextActionAbstain] = option("No available action can carry out the next clause, or the user must act first", notFor: "When an action clearly moves the goal forward; when the goal is already done (that is the goal_achieved gate, not this)", examples: [])
        return c
    }

    public static let goalMissingOptions: [String] = ["exact_dates", "destination", "origin", "product", "recipient", "content", "title", "nothing"]
    public static let goalMissingQuestion = Question.choice([
        "question": "If `goal` were carried out, which single required detail is most clearly missing or too vague to act on?",
        "focus": "Pick nothing when the goal can be carried out as stated, even if it is short. Opening, searching, navigating back, clicking a named control, typing a given value into a named field, or adding named items to a cart needs no more than the goal already says. Only a message with no recipient, a note or field with no content given, a booking with no dates, or a purchase with no product is missing something.",
        "examples": [["go to github then go back", "nothing"], ["type Ada in the first name field", "nothing"], ["add the blue mug to the cart", "nothing"],
                     ["send an email about the meeting", "recipient"], ["book a flight to paris", "exact_dates"], ["create a note", "nothing"]],
    ], [
        "exact_dates": "The dates or times needed are not given", "destination": "Where to go or send is not given", "origin": "Where from is not given",
        "product": "Which item or product is not given", "recipient": "Who it is for is not given", "content": "What to write or say is not given",
        "title": "What to call it is not given", "nothing": "Nothing is missing; the goal can be carried out as stated",
    ])

    public static let goalCompoundQuestion = Question.noul(
        ["question": "Does `goal` ask for several distinct steps in different apps or pages (for example search, then create a note with what was found), rather than one action or a short chain within one app?",
         "focus": "\"open notes and create a new note\" is one chain; \"research X and write a summary note\" is compound."],
        true: ["what": "Compound: worth splitting into subgoals"],
        false: ["what": "One action or a short chain"]
    )

    /// Clauses of a goal, split at step joiners ("then", "and then", "after that", "next", a
    /// comma, and "and" before a verb), so "salt and pepper" stays whole. A verb-less
    /// "<value> in the <name> field" after "and" is a clause too ("… and Lovelace in the last
    /// name field"). Ordered by position.
    public static func goalClauses(_ goal: String) -> [String] {
        let verbs: Set<String> = ["open", "search", "google", "create", "make", "type", "write", "click", "press", "go", "take", "scroll", "find", "look", "pull", "switch", "launch", "select", "choose", "add", "start", "close", "play", "put", "enter", "fill", "return", "navigate", "snap"]
        let words = goal.split(separator: " ").map(String.init)
        var segments: [[String]] = [[]]
        var i = 0
        func restLooksLikeValueInField(_ from: Int) -> Bool {
            let rest = words[from...].map { Transcript.normalizeToken($0) }.joined(separator: " ")
            return rest.range(of: #"^\S+ (in|into) the .*(field|box|search)\b"#, options: .regularExpression) != nil
        }
        while i < words.count {
            let w = Transcript.normalizeToken(words[i])
            let next = i + 1 < words.count ? Transcript.normalizeToken(words[i + 1]) : ""
            var cut = 0
            if w == "then" { cut = 1 }
            else if w == "and", next == "then" { cut = 2 }
            else if w == "after", next == "that" { cut = 2 }
            else if w == "and", verbs.contains(next) || (i + 1 < words.count && restLooksLikeValueInField(i + 1)) { cut = 1 }
            else if w == "next", verbs.contains(next) { cut = 1 }
            // "titled groceries" / "called X" / "named X" is its own step (typing the title), kept with its keyword.
            else if ["titled", "called", "named"].contains(w), !next.isEmpty, !segments[segments.count - 1].isEmpty { segments.append([]) }
            // "with milk and eggs as the body" is the content step of a note or field.
            else if w == "with", !next.isEmpty, !segments[segments.count - 1].isEmpty,
                    words[i...].map({ Transcript.normalizeToken($0) }).joined(separator: " ").range(of: #" as the (body|content|text|title|note)$"#, options: .regularExpression) != nil { segments.append([]) }
            let endsWithComma = words[i].hasSuffix(",")
            if cut > 0 { if !segments[segments.count - 1].isEmpty { segments.append([]) }; i += cut; continue }
            segments[segments.count - 1].append(words[i].trimmingCharacters(in: CharacterSet(charactersIn: ",")))
            if endsWithComma, !segments[segments.count - 1].isEmpty { segments.append([]) }
            i += 1
        }
        return segments.filter { !$0.isEmpty }.map { $0.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.")) }
    }

    /// Which clause of the goal the next action carries out (goal mode): spans and payloads
    /// come from that clause only, so a later step's words never leak into a query.
    public static func clauseQuestion(_ clauses: [String]) -> Question {
        var c: [String: JSONValue] = [:]
        for (i, cl) in clauses.enumerated() { c["c\(i + 1)"] = .string(cl) }
        return .choice([
            "question": "Which clause of `clauses` does the next action carry out, given `history` (actions already verified) and the observed state?",
            "focus": "Clauses are the goal's steps in order; the earliest one not yet verified in `history` is next. A clause like 'Lovelace in the last name field' means typing that value into that field.",
        ], c)
    }

    /// One request per goal-mode step: the three gates, the next action, and the speculative
    /// heads the next action may need (app, site, spans over the goal, targets over elements).
    public static func buildGoalStep(spans: SpanSet, goalText: String, installedApps: [String], runningApps: Set<String>,
                                     elements: [Element], offscreen: [Element], clauses: [String] = [], menus: [MenuItem] = []) -> [String: Question] {
        var q: [String: Question] = [
            "goal_achieved": goalAchievedQuestion,
            "blocked": blockedQuestion,
            "needs_reobserve": needsReobserveQuestion,
            "next_action": .choice(nextActionInstructions, nextActionCriteria),
            "app": .choice(appInstructions, appCriteria(installedApps: installedApps, runningApps: runningApps)),
            "site": .choice(siteInstructions, siteCriteria()),
            "destructive": destructiveQuestion,
            "scroll_amount": scrollAmountQuestion,
        ]
        if !spans.payload.isEmpty { q["text_span"] = textSpanQuestion(spans.payload, goalMode: true); q["type_placement"] = typePlacementQuestion() }
        if !spans.urls.isEmpty { q["url_span"] = urlSpanQuestion(spans.urls) }
        if clauses.count >= 2 { q["clause"] = clauseQuestion(clauses) }
        let clicks = clickable(elements), types = typeable(elements)
        if !clicks.isEmpty { q["click_target"] = clickTargetQuestion(clicks) }
        if !types.isEmpty { q["type_target"] = typeTargetQuestion(types, goalMode: true) }
        if !offscreen.isEmpty { q["offscreen_target"] = offscreenTargetQuestion(offscreen) }
        if !menus.isEmpty { q["menu_target"] = menuTargetQuestion(menus) }
        return q
    }

    /// Phase B of a multi-clause goal step: the argument heads for the chosen clause, with the
    /// clause as `transcript` so app, site, spans, and targets read the right words.
    public static func buildClauseArguments(spans: SpanSet, installedApps: [String], runningApps: Set<String>,
                                            elements: [Element], offscreen: [Element], menus: [MenuItem] = []) -> [String: Question] {
        var q: [String: Question] = [
            "app": .choice(appInstructions, appCriteria(installedApps: installedApps, runningApps: runningApps)),
            "site": .choice(siteInstructions, siteCriteria()),
            "scroll_amount": scrollAmountQuestion,
        ]
        if !spans.payload.isEmpty { q["text_span"] = textSpanQuestion(spans.payload, goalMode: true); q["type_placement"] = typePlacementQuestion() }
        if !spans.urls.isEmpty { q["url_span"] = urlSpanQuestion(spans.urls) }
        let clicks = clickable(elements), types = typeable(elements)
        if !clicks.isEmpty { q["click_target"] = clickTargetQuestion(clicks) }
        if !types.isEmpty { q["type_target"] = typeTargetQuestion(types, goalMode: true) }
        if !offscreen.isEmpty { q["offscreen_target"] = offscreenTargetQuestion(offscreen) }
        if !menus.isEmpty { q["menu_target"] = menuTargetQuestion(menus) }
        return q
    }

    /// Asked once before the loop: is anything missing, and is the goal compound.
    public static func buildGoalIntake() -> [String: Question] {
        ["goal_missing": goalMissingQuestion, "goal_compound": goalCompoundQuestion]
    }

    // MARK: Follow-up (a phrase that supplies what the last action needs)

    public static let followupSuppliesText = "supplies_text"
    public static let followupRepeatsAction = "repeats_action"
    public static let followupNewCommand = "new_command"
    public static let followupUnrelated = "unrelated"

    /// Asked only while `last_action` is recent. Jev reads the phrase against that action.
    public static func followupQuestion() -> Question {
        .choice([
            "question": "How does `transcript` relate to `last_action`, which the computer just performed for the user?",
            "focus": "supplies_text: the transcript is a topic, name, phrase, or search terms with no command verb of its own, spoken right after the computer opened a site, a search, an app, or a note, so it is what to look up or type there. repeats_action: the transcript asks to do `last_action` once more without naming a new one (again, do it again, once more, one more time, same again, do that again). new_command: the transcript is itself a command (it has a verb like open, search, type, scroll, click). unrelated: the transcript is conversation or narration, not directed at the computer.",
            "examples": [
                ["last_action open_site wikipedia; transcript 'mark zuckerberg'", "supplies_text"],
                ["last_action open_app Notes; transcript 'groceries for the week'", "supplies_text"],
                ["last_action web_search google 'cats'; transcript 'persian cats'", "supplies_text"],
                ["last_action scroll_down page; transcript 'again'", "repeats_action"],
                ["last_action take_photo; transcript 'one more time'", "repeats_action"],
                ["last_action scroll_down page; transcript 'do it again'", "repeats_action"],
                ["last_action press_enter; transcript 'once more'", "repeats_action"],
                ["last_action open_app Notes; transcript 'open chrome'", "new_command"],
                ["last_action open_site wikipedia; transcript 'I think that went well'", "unrelated"],
                ["last_action scroll_down page; transcript 'let me read this again'", "unrelated"],
                ["last_action open_app Notes; transcript 'she told me about mark zuckerberg yesterday'", "unrelated"],
            ],
        ], [
            followupSuppliesText: "The words are what the last action needs: search terms for the site or search just opened, or text for the note, field, or app just opened",
            followupRepeatsAction: "A request to perform `last_action` again, with no new target of its own (again, do it again, once more, one more time)",
            followupNewCommand: "A new command with its own verb",
            followupUnrelated: "Conversation or narration, not meant for the computer",
        ])
    }

    // MARK: Target heads (Phase 4, plan section 7)

    public static let targetNone = "none"
    public static let targetFocused = "focused"

    /// One-line description of an element as an option, e.g. `button 'Take Photo' (bottom-center)`.
    public static func describe(_ e: Element, mates: [String]? = nil) -> String {
        let text = String(e.text.prefix(Config.maxElementTextChars))
        var place = e.container.map { "\(e.where), in \($0)" } ?? e.where
        if let mates, !mates.isEmpty { place += "; in the row of " + mates.map { "'\($0)'" }.joined(separator: ", ") }
        return text.isEmpty ? "\(e.role) with no label (\(place))" : "\(e.role) '\(text)' (\(place))"
    }

    /// For each element whose label another element repeats, the labels sharing its row, left
    /// to right: three rows each ending in "Buy" say nothing by label, and the row is a fact the
    /// layout holds (awlevin's row_mates). Keyed by element id; unique labels get no entry.
    public static func rowMates(_ elements: [Element], limit: Int = 3) -> [String: [String]] {
        func key(_ e: Element) -> String { e.text.trimmingCharacters(in: .whitespaces).lowercased() }
        var counts: [String: Int] = [:]
        for e in elements where !e.text.isEmpty { counts[key(e), default: 0] += 1 }
        var out: [String: [String]] = [:]
        for e in elements where counts[key(e), default: 0] >= 2 {
            let cy = e.frame.y + e.frame.height / 2, half = max(1, e.frame.height) / 2
            let mates = elements
                .filter { $0.id != e.id && !$0.text.isEmpty && key($0) != key(e) && abs(($0.frame.y + $0.frame.height / 2) - cy) < half }
                .sorted { $0.frame.x < $1.frame.x }
            if !mates.isEmpty { out[e.id] = mates.prefix(limit).map { String($0.text.prefix(30)) } }
        }
        return out
    }

    public static func clickable(_ elements: [Element]) -> [Element] { Array(elements.prefix(Config.maxElementsInState)).filter { !$0.editable } }
    public static func typeable(_ elements: [Element]) -> [Element] { Array(elements.prefix(Config.maxElementsInState)).filter { $0.editable && !$0.secure } }

    public static func clickTargetQuestion(_ elements: [Element]) -> Question {
        var criteria: [String: JSONValue] = [:]
        let mates = rowMates(elements)
        for e in elements { criteria[e.id] = .string(describe(e, mates: mates[e.id])) }
        criteria[targetNone] = "The command does not refer to any clickable element on this screen"
        return .choice([
            "question": "If the next action is to click, which element in `elements` is the one the user refers to in `transcript`?",
            "focus": "Each element has an id, a role, visible text, and a coarse position; the options are the ids of the clickable elements. Elements are in visual reading order, so 'first' means the earliest matching one and 'second' the next. Match on the words the user said; a spoken label beats a position. Pick none if the command does not refer to any clickable element on this screen.",
        ], criteria)
    }

    public static func typeTargetQuestion(_ elements: [Element], goalMode: Bool = false) -> Question {
        var criteria: [String: JSONValue] = [:]
        let mates = rowMates(elements)
        for e in elements { criteria[e.id] = .string(describe(e, mates: mates[e.id])) }
        criteria[targetFocused] = "The command names no field; the text goes into the currently focused field (`focused_field`)"
        criteria[targetNone] = "There is no editable field to type into"
        var focus = "Pick focused if the command names no field and the text should go into the currently focused field. Pick none if there is no editable field to type into."
        if goalMode { focus += " When `transcript` names several fields with values, `history` shows which were typed already: pick the field for the next value not yet typed." }
        return .choice([
            "question": "If the next action is to type, which editable field in `elements` does the user name in `transcript`?",
            "focus": .string(focus),
        ], criteria)
    }

    /// Menu commands whose words the transcript could name, plus a few that spoken synonyms
    /// reach; capped so the head stays small. Code filters, Jev selects.
    public static func relevantMenus(_ menus: [MenuItem], transcript: String, cap: Int = Config.maxMenusInState) -> [MenuItem] {
        let stop: Set<String> = ["the", "a", "an", "this", "that", "it", "to", "in", "on", "of", "and", "please", "up", "app", "window", "page", "menu", "item", "now"]
        let synonyms: [String: [String]] = ["refresh": ["reload"], "search": ["find"], "exit": ["close"], "shut": ["close"], "bigger": ["zoom in", "increase"], "smaller": ["zoom out", "decrease"],
                                            "larger": ["zoom in"], "duplicate": ["duplicate", "copy"], "fullscreen": ["full screen"], "full": ["full screen"]]
        var words = Set(Transcript.normalize(transcript).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
        for w in Array(words) { for syn in synonyms[w] ?? [] { words.insert(syn) } }
        guard !words.isEmpty else { return [] }
        let hits = menus.filter { m in
            let t = m.path.lowercased()
            return words.contains { t.contains($0) }
        }
        return Array(hits.prefix(cap))
    }

    public static func menuTargetQuestion(_ menus: [MenuItem]) -> Question {
        var criteria: [String: JSONValue] = [:]
        for m in menus { criteria[m.id] = .string(m.path) }
        criteria[targetNone] = "None of these menu commands is the one the user names"
        return .choice([
            "question": "If the next action is a menu command, which of these menu-bar items in the front app does the user name in `transcript`?",
            "focus": "Match the command's own words to the item's name: \"close the window\" is Close, not Close All; \"new tab\" is New Tab, not New Window; \"save\" is Save, not Save As. Pick none when nothing listed is what the user means.",
        ], criteria)
    }

    public static func offscreenTargetQuestion(_ elements: [Element]) -> Question {
        var criteria: [String: JSONValue] = [:]
        let mates = rowMates(elements)
        for e in elements { criteria[e.id] = .string(describe(e, mates: mates[e.id])) }
        criteria[targetNone] = "None of these off-screen controls is the one the user means"
        return .choice([
            "question": "If the control the user refers to in `transcript` is not visible but the app exposes it, which of these labelled off-screen controls should be pressed?",
            "focus": "Only a control whose label matches what the user said. Pick none otherwise.",
        ], criteria)
    }

    // MARK: Assembly

    /// Everything for one request. Target heads (Phase 4) are added when the matching element
    /// subset is non-empty, so a click can never land on a text field and a type never on a button.
    public static func build(spans: SpanSet, installedApps: [String] = [], runningApps: Set<String> = [], rawTranscript: String? = nil,
                             elements: [Element] = [], offscreen: [Element] = [], followup: Bool = false, menus: [MenuItem] = []) -> [String: Question] {
        var q: [String: Question] = [
            "intent": .choice(intentInstructions, intentCriteria),
            "app": .choice(appInstructions, appCriteria(installedApps: installedApps, runningApps: runningApps)),
            "site": .choice(siteInstructions, siteCriteria()),
            "complete": completeQuestion,
            "is_command": isCommandQuestion,
            "destructive": destructiveQuestion,
            "scroll_amount": scrollAmountQuestion,
        ]
        if !spans.payload.isEmpty { q["text_span"] = textSpanQuestion(spans.payload); q["type_placement"] = typePlacementQuestion() }
        if !spans.urls.isEmpty { q["url_span"] = urlSpanQuestion(spans.urls) }
        if let raw = rawTranscript {
            let prefixes = commandPrefixes(raw)
            if !prefixes.isEmpty { q["command_span"] = commandSpanQuestion(prefixes) }
        }
        if followup { q["followup"] = followupQuestion() }
        let clicks = clickable(elements), types = typeable(elements)
        if !clicks.isEmpty { q["click_target"] = clickTargetQuestion(clicks) }
        if !types.isEmpty { q["type_target"] = typeTargetQuestion(types) }
        if !offscreen.isEmpty { q["offscreen_target"] = offscreenTargetQuestion(offscreen) }
        if !menus.isEmpty { q["menu_target"] = menuTargetQuestion(menus) }
        return q
    }
}
