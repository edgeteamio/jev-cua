import Testing
@testable import JevCore

/// Every gate in plan 9.4, driven by hand-built answers. No network.
@Suite struct PolicyTests {
    func choice(_ pick: String, _ options: [String], conf: Double = 0.9) -> Answer {
        var p = [String: Double]()
        let rest = (1 - 0.85) / Double(max(1, options.count - 1))
        for o in options { p[o] = o == pick ? 0.85 : rest }
        return .choice(ChoiceAnswer(choice: pick, probabilities: p, confidence: conf))
    }

    func answers(intent: String, conf: Double = 0.9, isCommand: Double = 0.95, complete: Double = 0.9, destructive: Double = 0.05,
                 app: String = "not_stated", site: String = "not_stated", span: String? = nil, spanConf: Double = 0.9,
                 url: String? = nil) -> [String: Answer] {
        var a: [String: Answer] = [
            "intent": choice(intent, Questions.intentOptions, conf: conf),
            "app": choice(app, Array(Questions.appCriteria().keys)),
            "site": choice(site, Array(Questions.siteCriteria().keys)),
            "complete": .noul(complete),
            "is_command": .noul(isCommand),
            "destructive": .noul(destructive),
            "scroll_amount": .score(ScoreAnswer(score: 1.0, probabilities: ["0": 0.1, "1": 0.8, "2": 0.1], confidence: 0.7)),
        ]
        if let span { a["text_span"] = .choice(ChoiceAnswer(choice: span, probabilities: [span: 0.8, "none": 0.2], confidence: spanConf)) }
        if let url { a["url_span"] = .choice(ChoiceAnswer(choice: url, probabilities: [url: 0.9, "none": 0.1], confidence: 0.8)) }
        return a
    }

    func input(_ raw: String, isFinal: Bool, intent: String, silentMs: Double = 0, stable: Bool = true, field: FocusedField? = nil,
               pending: Candidate? = nil, bundle: String? = nil, mutate: ((inout [String: Answer]) -> Void)? = nil,
               app: String = "not_stated", site: String = "not_stated", span: String? = nil, spanConf: Double = 0.9, url: String? = nil,
               isCommand: Double = 0.95, complete: Double = 0.9, conf: Double = 0.9, destructive: Double = 0.05) -> PolicyInput {
        var a = answers(intent: intent, conf: conf, isCommand: isCommand, complete: complete, destructive: destructive, app: app, site: site, span: span, spanConf: spanConf, url: url)
        mutate?(&a)
        return PolicyInput(answers: a, spans: Spans.extract(from: raw),
                           context: DecisionContext(rawTranscript: raw, isFinal: isFinal, frontmostBundleId: bundle, focusedField: field, pendingConfirmation: pending?.action.summary),
                           silentMs: silentMs, intentStable: stable, pending: pending)
    }

    func elements() -> [Element] {
        [Element(id: "e01", role: "button", text: "Take Photo", where: "bottom-center", editable: false, secure: false, frame: Frame(x: 300, y: 500, width: 60, height: 30)),
         Element(id: "e02", role: "button", text: "Effects", where: "bottom-right", editable: false, secure: false, frame: Frame(x: 500, y: 500, width: 60, height: 30)),
         Element(id: "e03", role: "textfield", text: "Search", where: "top-right", editable: true, secure: false, frame: Frame(x: 500, y: 10, width: 120, height: 24)),
         Element(id: "e04", role: "securetextfield", text: "Password", where: "center", editable: true, secure: true, frame: Frame(x: 300, y: 300, width: 120, height: 24))]
    }

    func target(_ pick: String, probs: [String: Double], conf: Double) -> Answer {
        .choice(ChoiceAnswer(choice: pick, probabilities: probs, confidence: conf))
    }

    @Test func targetHeadsOnlyOfferCompatibleElements() {
        let q = Questions.build(spans: Spans.extract(from: "press take photo"), elements: elements())
        guard case .choice(let click)? = q["click_target"], case .choice(let type)? = q["type_target"] else { Issue.record("heads missing"); return }
        #expect(Set(click.criteria.keys) == ["e01", "e02", "none"])
        #expect(Set(type.criteria.keys) == ["e03", "focused", "none"], "secure fields are never typed into")
        #expect(click.criteria["e01"]?.stringValue == "button 'Take Photo' (bottom-center)")
        #expect(Questions.build(spans: Spans.extract(from: "x"))["click_target"] == nil)
    }

    @Test func confidentClickTargetActs() {
        var i = input("press take photo", isFinal: true, intent: "click_element", mutate: { a in
            a["click_target"] = self.target("e01", probs: ["e01": 0.85, "e02": 0.1, "none": 0.05], conf: 0.8)
        })
        i.context.elements = elements()
        let r = Policy.evaluate(i)
        #expect(r.outcome.name == "act")
        #expect(r.candidate?.action == .clickElement(elementId: "e01"))
        #expect(r.candidate?.targetElementId == "e01")
        #expect(r.candidate?.humanLabel == "Click “Take Photo”", "the chip names the element, not its id")
    }

    @Test func ambiguousClickTargetDisambiguates() {
        var i = input("click the button", isFinal: true, intent: "click_element", mutate: { a in
            a["click_target"] = self.target("e01", probs: ["e01": 0.46, "e02": 0.44, "none": 0.1], conf: 0.2)
        })
        i.context.elements = elements()
        let r = Policy.evaluate(i)
        #expect(r.outcome == .disambiguate(candidateIds: ["e01", "e02"]))
        #expect(r.candidate == nil)
    }

    @Test func clickTargetNoneWaits() {
        var i = input("click the thing", isFinal: true, intent: "click_element", mutate: { a in
            a["click_target"] = self.target("none", probs: ["e01": 0.05, "e02": 0.05, "none": 0.9], conf: 0.9)
        })
        i.context.elements = elements()
        #expect(Policy.evaluate(i).outcome == .wait(reason: "which element?", retryInMs: nil))
    }

    @Test func offscreenTargetUsedOnlyWhenNothingVisibleMatches() {
        var i = input("press the export button", isFinal: true, intent: "click_element", mutate: { a in
            a["click_target"] = self.target("none", probs: ["e01": 0.05, "e02": 0.05, "none": 0.9], conf: 0.9)
            a["offscreen_target"] = self.target("o001", probs: ["o001": 0.9, "none": 0.1], conf: 0.85)
        })
        i.context.elements = elements()
        i.context.offscreen = [Element(id: "o001", role: "button", text: "Export", where: "bottom-left", editable: false, secure: false, frame: Frame(x: 0, y: 2000, width: 60, height: 30))]
        let r = Policy.evaluate(i)
        #expect(r.candidate?.action == .clickElement(elementId: "o001"))
    }

    @Test func namedTypeTargetBeatsFocusedField() {
        var i = input("type hello in the search field", isFinal: true, intent: "type_text", mutate: { a in
            a["type_target"] = self.target("e03", probs: ["e03": 0.8, "focused": 0.15, "none": 0.05], conf: 0.7)
        }, span: "hello")
        i.context.elements = elements()
        let r = Policy.evaluate(i)
        #expect(r.candidate?.action == .typeText(text: "hello"))
        #expect(r.candidate?.targetElementId == "e03")
        // Without a focused field and with the head saying focused, nothing to type into.
        var j = input("type hello", isFinal: true, intent: "type_text", mutate: { a in
            a["type_target"] = self.target("focused", probs: ["e03": 0.1, "focused": 0.85, "none": 0.05], conf: 0.8)
        }, span: "hello")
        j.context.elements = elements()
        #expect(Policy.evaluate(j).outcome == .wait(reason: "no field focused", retryInMs: nil))
    }

    @Test func spokenChoiceParsing() {
        #expect(CommandSession.spokenChoice("two", count: 3) == 2)
        #expect(CommandSession.spokenChoice("the second one", count: 3) == 2)
        #expect(CommandSession.spokenChoice("number 3", count: 3) == 3)
        #expect(CommandSession.spokenChoice("click the first", count: 2) == 1)
        #expect(CommandSession.spokenChoice("four", count: 3) == nil, "out of range")
        #expect(CommandSession.spokenChoice("open the second tab", count: 3) == nil, "a real command, not a pick")
        #expect(CommandSession.spokenChoice("one two", count: 3) == nil)
    }

    @Test func nonCommandIsIgnored() {
        let r = Policy.evaluate(input("the weather is nice", isFinal: true, intent: "none", isCommand: 0.1))
        #expect(r.outcome == .ignore(reason: "not a command"))
    }

    @Test func noneIntentWaits() {
        let r = Policy.evaluate(input("open the", isFinal: false, intent: "none"))
        #expect(r.outcome.name == "wait")
    }

    @Test func allowlistedIntentFiresOnStablePartial() {
        let r = Policy.evaluate(input("open the notes app and cre", isFinal: false, intent: "open_app", stable: true, app: "notes"))
        #expect(r.outcome.name == "act")
        #expect(r.candidate?.action == .openApp(bundleId: "com.apple.Notes", name: "Notes"))
    }

    @Test func appNameThatCouldContinueHoldsAnEarlyFire() {
        // "launch photo" with Photos installed: Jev picks Photos, but the words so far are also the
        // start of "Photo Booth" (lab 2026-09-20), and "photo" could still grow into "photos".
        var i = input("launch photo", isFinal: false, intent: "open_app", stable: true, app: "app:photos", conf: 0.99)
        i.context.installedApps = ["Photos", "Photo Booth"]
        let held = Policy.evaluate(i)
        #expect(held.outcome == .wait(reason: "app name may continue", retryInMs: Config.throttleMs))
        #expect(held.reasons.last?.name == "app_name_final")
        // The full name is not a prefix of anything else: fire.
        var j = input("launch photo booth", isFinal: false, intent: "open_app", stable: true, app: "photo_booth", conf: 0.99)
        j.context.installedApps = ["Photos", "Photo Booth"]
        #expect(Policy.evaluate(j).outcome.name == "act")
        // Committed by a final: the hold does not apply.
        var k = input("launch photo", isFinal: true, intent: "open_app", stable: true, app: "app:photos", conf: 0.99)
        k.context.installedApps = ["Photos", "Photo Booth"]
        #expect(Policy.evaluate(k).outcome.name == "act")
    }

    @Test func partialWaitsWhenIntentJustChangedUnlessVeryConfident() {
        let unsure = Policy.evaluate(input("open the notes app", isFinal: false, intent: "open_app", stable: false, app: "notes", conf: 0.7))
        #expect(unsure.outcome == .wait(reason: "intent not yet stable", retryInMs: Config.throttleMs))
        let sure = Policy.evaluate(input("open the notes app", isFinal: false, intent: "open_app", stable: false, app: "notes", conf: 0.95))
        #expect(sure.outcome.name == "act")
    }

    @Test func partialWaitsWhenIncomplete() {
        let r = Policy.evaluate(input("open the", isFinal: false, intent: "open_app", app: "notes", complete: 0.2))
        #expect(r.outcome.name == "wait")
        #expect(r.reasons.last?.name == "complete")
    }

    @Test func nonAllowlistedIntentWaitsUntilCommitted() {
        let partial = Policy.evaluate(input("take a picture of me", isFinal: false, intent: "take_photo"))
        #expect(partial.outcome.name == "wait")
        #expect(partial.reasons.last?.name == "early_allowlist")
        let final = Policy.evaluate(input("take a picture of me", isFinal: true, intent: "take_photo"))
        #expect(final.outcome.name == "act")
        #expect(final.candidate?.action == .takePhoto)
    }

    @Test func silenceCommitsWithoutFinal() {
        let r = Policy.evaluate(input("take a picture of me", isFinal: false, intent: "take_photo", silentMs: 950))
        #expect(r.outcome.name == "act")
    }

    @Test func webSearchBuildsUrlFromPickedSpan() {
        let r = Policy.evaluate(input("google search norbert wiener", isFinal: true, intent: "web_search", site: "google", span: "norbert wiener"))
        #expect(r.outcome.name == "act")
        if case .webSearch(let url, let q, let site) = r.candidate!.action {
            #expect(q == "norbert wiener"); #expect(site == "google"); #expect(url.contains("norbert%20wiener"))
        } else { Issue.record("expected webSearch") }
    }

    @Test func webSearchProceedsOnLowConfidenceSpanButTypeAsks() {
        let s = Policy.evaluate(input("search for alan turing", isFinal: true, intent: "web_search", span: "alan turing", spanConf: 0.2))
        #expect(s.outcome.name == "act")
        let field = FocusedField(role: "textarea", label: "Note")
        let t = Policy.evaluate(input("type hello there", isFinal: true, intent: "type_text", field: field, span: "hello there", spanConf: 0.2))
        #expect(t.outcome == .wait(reason: "type what?", retryInMs: nil))
    }

    @Test func typeTextNeedsAnEditableField() {
        let noField = Policy.evaluate(input("type hello", isFinal: true, intent: "type_text", span: "hello"))
        #expect(noField.outcome == .wait(reason: "no field focused", retryInMs: nil))
        let secure = Policy.evaluate(input("type hello", isFinal: true, intent: "type_text", field: FocusedField(role: "textfield", secure: true), span: "hello"))
        #expect(secure.outcome.name == "wait")
        let ok = Policy.evaluate(input("type hello", isFinal: true, intent: "type_text", field: FocusedField(role: "textarea"), span: "hello"))
        #expect(ok.candidate?.action == .typeText(text: "hello"))
    }

    @Test func placementReplacesOnlyOnAConfidentHead() {
        let field = FocusedField(role: "textarea", label: "Note", valuePreview: "shopping")
        func placement(_ raw: String, _ choice: String, conf: Double) -> Action? {
            Policy.evaluate(input(raw, isFinal: true, intent: "type_text", field: field, mutate: { a in
                a["type_placement"] = .choice(ChoiceAnswer(choice: choice, probabilities: [choice: 0.8, "insert": 0.2], confidence: conf))
            }, span: "groceries")).candidate?.action
        }
        #expect(placement("change the title to groceries", "replace_title", conf: 0.8) == .typeText(text: "groceries", placement: .replaceTitle))
        #expect(placement("replace the text with groceries", "replace_all", conf: 0.8) == .typeText(text: "groceries", placement: .replaceAll))
        // Unsure: insert, which loses nothing the user cannot see.
        #expect(placement("change the title to groceries", "replace_title", conf: 0.4) == .typeText(text: "groceries", placement: .insert))
        // No head answered (no payload span was offered): insert.
        let plain = Policy.evaluate(input("type groceries", isFinal: true, intent: "type_text", field: field, span: "groceries"))
        #expect(plain.candidate?.action == .typeText(text: "groceries"))
        #expect(plain.candidate?.expectedPostcondition == "focused field value contains the text")
    }

    @Test func spokenDomainIsPayloadAndCatalogSiteIsNot() {
        let partial = Policy.evaluate(input("open x dot com", isFinal: false, intent: "open_site", site: "x_twitter", url: "x dot com"))
        #expect(partial.reasons.last?.name == "payload_final")
        #expect(partial.outcome.name == "wait")
        let final = Policy.evaluate(input("open x dot com", isFinal: true, intent: "open_site", site: "x_twitter", url: "x dot com"))
        #expect(final.candidate?.action == .openSite(url: "https://x.com/", label: "x dot com"))
        // A searchable site waits for the words to settle (a query may follow), then fires early.
        let fresh = Policy.evaluate(input("go to wikipedia", isFinal: false, intent: "open_site", site: "wikipedia"))
        #expect(fresh.outcome == .wait(reason: "a query may follow the site name", retryInMs: Config.T.earlyScrollStableMs))
        var settled = input("go to wikipedia", isFinal: false, intent: "open_site", site: "wikipedia")
        settled.transcriptStableMs = 350
        let catalog = Policy.evaluate(settled)
        #expect(catalog.outcome.name == "act")
        #expect(catalog.candidate?.action == .openSite(url: "https://en.wikipedia.org/wiki/Main_Page", label: "wikipedia"))
    }

    @Test func gatedTierAsksForConfirmationWhenDestructive() {
        // press_enter is gated; with destructive high it needs a spoken confirm.
        let r = Policy.evaluate(input("press enter", isFinal: true, intent: "press_enter", destructive: 0.8))
        #expect(r.outcome.name == "confirm")
        let safe = Policy.evaluate(input("press enter", isFinal: true, intent: "press_enter", destructive: 0.1))
        #expect(safe.outcome.name == "act")
    }

    @Test func pendingConfirmationIsResolvedByConfirmOrCancel() {
        let pending = Candidate(id: "p1", snapshotId: "s", action: .pressEnter, expectedPostcondition: "")
        let yes = Policy.evaluate(input("confirm", isFinal: true, intent: "confirm", pending: pending))
        #expect(yes.outcome == .act(candidateId: "p1"))
        let no = Policy.evaluate(input("cancel", isFinal: true, intent: "cancel", pending: pending))
        #expect(no.outcome == .ignore(reason: "cancelled"))
    }

    @Test func denyListBlocksTypingInDeniedApps() {
        let r = Policy.evaluate(input("type hello", isFinal: true, intent: "type_text", field: FocusedField(role: "textarea"),
                                      bundle: "com.apple.MobileSMS", span: "hello"))
        #expect(r.outcome.name == "ignore")
        #expect(r.reasons.last?.name == "deny_list")
    }

    @Test func scrollAmountFromScore() {
        let r = Policy.evaluate(input("scroll down a bit", isFinal: true, intent: "scroll_down", mutate: {
            $0["scroll_amount"] = .score(ScoreAnswer(score: 0.2, probabilities: ["0": 0.8, "1": 0.2, "2": 0], confidence: 0.6))
        }))
        #expect(r.candidate?.action == .scroll(direction: .down, amount: .little))
    }

    @Test func clickWithoutElementsWaits() {
        let r = Policy.evaluate(input("click the first result", isFinal: true, intent: "click_element"))
        #expect(r.outcome == .wait(reason: "no clickable element on this screen", retryInMs: nil))
    }

    @Test func stateHasOnlyTheAgreedFields() {
        let ctx = DecisionContext(rawTranscript: "Open Chrome.", isFinal: false, frontmostApp: "Finder", recentActions: ["a", "b", "c", "d"])
        let s = StateBuilder.state(for: ctx)
        #expect(s["transcript"]?.stringValue == "open chrome")
        #expect(s["recent_actions"]?.arrayValue?.count == 3)
        #expect(Set(s.objectValue!.keys) == ["transcript", "transcript_is_final", "frontmost_app", "focused_field", "pending_confirmation", "recent_actions", "last_action", "page_host", "elements"])
        // Menus appear only when some are relevant to the words.
        var withMenus = ctx
        withMenus.menus = [MenuItem(id: "m01", path: "File › Save")]
        let s2 = StateBuilder.state(for: withMenus)
        #expect(s2["menus"]?.arrayValue?.map(\.stringValue) == ["m01 File › Save"])
    }

    @Test func questionCatalogShape() {
        let q = Questions.build(spans: Spans.extract(from: "google search norbert wiener"), installedApps: ["Notes", "Blender"], runningApps: ["Blender"])
        #expect(Set(q.keys) == ["intent", "app", "site", "complete", "is_command", "destructive", "scroll_amount", "text_span", "type_placement"])
        if case .choice(let c) = q["app"]! {
            #expect(c.criteria["app:blender"] == "Blender (running)")
            #expect(c.criteria["app:notes"] == nil)   // catalog entry, not duplicated
            #expect(c.criteria["notes"] != nil)
        } else { Issue.record("app should be a choice") }
        if case .choice(let c) = q["intent"]! { #expect(c.criteria.count == 16) }
        let withUrl = Questions.build(spans: Spans.extract(from: "open x dot com"))
        #expect(withUrl["url_span"] != nil)
        let rel = Questions.relevantInstalledApps(["Blender", "Notes", "Visual Studio Code", "Slack", "Photo Booth"], transcript: "open blender and then slack")
        #expect(rel == ["Blender", "Slack"])
        #expect(Questions.relevantInstalledApps(["Blender"], transcript: "open the notes app").isEmpty)
        #expect(Questions.commandPrefixes("open the notes app") == ["open", "open the", "open the notes", "open the notes app"])
        #expect(Questions.commandPrefixes("open").isEmpty)
    }
    @Test func spokenCountRepeatsARepeatableAction() {
        let three = Policy.evaluate(input("scroll down three times", isFinal: true, intent: "scroll_down"))
        #expect(three.candidate?.repeats == 3)
        // "n times" counts screens, not the nudges a bare scroll gives.
        #expect(three.candidate?.action == .scroll(direction: .down, amount: .page))
        #expect(three.candidate?.summary == "scroll_down page ×3")
        let twice = Policy.evaluate(input("go back twice", isFinal: true, intent: "go_back"))
        #expect(twice.candidate?.repeats == 2)
        // A bare number is not a count (it could be an ordinal or dictation).
        let plain = Policy.evaluate(input("scroll down", isFinal: true, intent: "scroll_down"))
        #expect(plain.candidate?.repeats == 1)
        // Typing is not repeated by a spoken count.
        let typed = Policy.evaluate(input("type hello three times", isFinal: true, intent: "type_text", field: FocusedField(role: "textarea"), span: "hello three times"))
        #expect(typed.candidate?.repeats == 1)
    }

    @Test func menuCommandSelectsFromTheOfferedItems() {
        var i = input("close the window", isFinal: true, intent: "menu_item", mutate: { a in
            a["menu_target"] = self.target("m03", probs: ["m03": 0.9, "none": 0.1], conf: 0.85)
        })
        i.context.menus = [MenuItem(id: "m01", path: "File › New Window"), MenuItem(id: "m03", path: "File › Close Window")]
        let r = Policy.evaluate(i)
        #expect(r.candidate?.action == .menuItem(id: "m03", path: "File › Close Window"))
        // A destructive menu path is denied even when Jev picks it confidently.
        var j = input("delete the note", isFinal: true, intent: "menu_item", mutate: { a in
            a["menu_target"] = self.target("m09", probs: ["m09": 0.95, "none": 0.05], conf: 0.9)
        })
        j.context.menus = [MenuItem(id: "m09", path: "File › Move to Trash")]
        #expect(Policy.evaluate(j).outcome.name == "ignore")
        // No menu offered: waits rather than acting.
        let none = Policy.evaluate(input("save", isFinal: true, intent: "menu_item"))
        #expect(none.outcome.name == "wait")
    }

    @Test func relevantMenusFilterByWordsAndSynonyms() {
        let menus = [MenuItem(id: "m1", path: "File › Save"), MenuItem(id: "m2", path: "View › Reload This Page"),
                     MenuItem(id: "m3", path: "Edit › Select All"), MenuItem(id: "m4", path: "Window › Minimize")]
        // "refresh" reaches "Reload" through a synonym; "save" matches directly.
        #expect(Set(Questions.relevantMenus(menus, transcript: "refresh the page").map(\.id)) == ["m2"])
        #expect(Set(Questions.relevantMenus(menus, transcript: "save this").map(\.id)) == ["m1"])
        // Stop words alone match nothing.
        #expect(Questions.relevantMenus(menus, transcript: "the it now").isEmpty)
    }

    @Test func repeatFollowupRerunsTheLastAction() {
        func repeatInput(_ raw: String, last: Action?, choice: String = Questions.followupRepeatsAction, conf: Double = 0.9) -> PolicyInput {
            var i = input(raw, isFinal: true, intent: "none", mutate: { a in
                a["followup"] = .choice(ChoiceAnswer(choice: choice, probabilities: [choice: 0.85, "unrelated": 0.15], confidence: conf))
            }, isCommand: 0.4, conf: 0.2)
            i.context.lastAction = last
            i.context.lastActionAgeS = 2
            return i
        }
        // "again" re-runs the last scroll.
        let r = Policy.evaluate(repeatInput("again", last: .scroll(direction: .down, amount: .page)))
        #expect(r.candidate?.action == .scroll(direction: .down, amount: .page))
        #expect(r.candidate?.repeats == 1)
        // "twice more" repeats a repeatable action two times.
        let two = Policy.evaluate(repeatInput("do it twice more", last: .scroll(direction: .down, amount: .page)))
        #expect(two.candidate?.repeats == 2)
        // take_photo again works; it is not repeatable so a count does not multiply it.
        let photo = Policy.evaluate(repeatInput("one more time", last: .takePhoto))
        #expect(photo.candidate?.action == .takePhoto)
        // A repeat of a past click is refused (stale element id).
        let click = Policy.evaluate(repeatInput("again", last: .clickElement(elementId: "e05")))
        #expect(click.outcome.name == "wait")
        // No last action: nothing to repeat.
        let none = Policy.evaluate(repeatInput("again", last: nil))
        #expect(none.outcome.name != "act")
        // Low confidence on the relation does not fire.
        let unsure = Policy.evaluate(repeatInput("again", last: .goBack, conf: 0.4))
        #expect(unsure.outcome.name != "act")
    }

    @Test func duplicatedLabelsCarryTheirRow() {
        func el(_ id: String, _ role: String, _ text: String, x: Double, y: Double) -> Element {
            Element(id: id, role: role, text: text, where: "center", editable: false, secure: false, frame: Frame(x: x, y: y, width: 80, height: 20))
        }
        let els = [el("e01", "link", "Coldplay", x: 10, y: 100), el("e02", "button", "Buy", x: 400, y: 100),
                   el("e03", "link", "Muse", x: 10, y: 200), el("e04", "button", "Buy", x: 400, y: 200),
                   el("e05", "button", "Checkout", x: 400, y: 300)]
        let mates = Questions.rowMates(els)
        #expect(mates["e02"] == ["Coldplay"])
        #expect(mates["e04"] == ["Muse"])
        #expect(mates["e05"] == nil, "a unique label needs no row")
        #expect(mates["e01"] == nil)
        #expect(Questions.describe(els[1], mates: mates["e02"]) == "button 'Buy' (center; in the row of 'Coldplay')")
        if case .choice(let c) = Questions.clickTargetQuestion(els) {
            #expect(c.criteria["e04"]?.stringValue?.contains("in the row of 'Muse'") == true)
            #expect(c.criteria["e05"]?.stringValue?.contains("row of") == false)
        } else { Issue.record("click_target should be a choice") }
    }

    @Test func aVisibleControlAndAMenuCommandAreOneWish() {
        // "close the window": Jev splits between the close button and File › Close; a confident
        // click target makes it a click (no menu needed).
        var i = input("close the window", isFinal: true, intent: "menu_item", mutate: { a in
            a["intent"] = .choice(ChoiceAnswer(choice: "menu_item", probabilities: ["menu_item": 0.46, "click_element": 0.44, "none": 0.1], confidence: 0.3))
            a["click_target"] = self.target("e01", probs: ["e01": 0.9, "none": 0.1], conf: 0.85)
        })
        i.context.elements = [Element(id: "e01", role: "button", text: "Close", where: "top-left", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 12, height: 12))]
        let r = Policy.evaluate(i)
        #expect(r.candidate?.action == .clickElement(elementId: "e01"))
        #expect(r.reasons.contains { $0.name == "intent_merge" })
        // A clear menu_item intent with no menu offered still clicks the confident control.
        var j = input("close the window", isFinal: true, intent: "menu_item", mutate: { a in
            a["click_target"] = self.target("e01", probs: ["e01": 0.9, "none": 0.1], conf: 0.85)
        })
        j.context.elements = i.context.elements
        #expect(Policy.evaluate(j).candidate?.action == .clickElement(elementId: "e01"))
        // Neither a menu nor a confident control: waits.
        let k = Policy.evaluate(input("close the window", isFinal: true, intent: "menu_item"))
        #expect(k.outcome.name == "wait")
    }

    /// "close the chrome tab" (run 2026-09-28T21-35-37Z): menu_item at 1.00 with click_element
    /// second by a rounding error, File › Close Tab at 0.96, the window's close button at 0.58. The
    /// merge fired on that tie, the close button won, and the whole window closed.
    @Test func aClearMenuIntentIsNoSplitAndATabNeverClosesTheWindow() {
        let closeWindow = Element(id: "e37", role: "button", text: Element.closeWindowLabel, where: "top-left", editable: false, secure: false, frame: Frame(x: 18, y: 145, width: 16, height: 16))
        var i = input("close the chrome tab", isFinal: true, intent: "menu_item", mutate: { a in
            a["intent"] = .choice(ChoiceAnswer(choice: "menu_item", probabilities: ["menu_item": 0.9999, "click_element": 0.00004, "cancel": 0.00003, "none": 0.00003], confidence: 0.99))
            a["menu_target"] = self.target("m18", probs: ["m18": 0.96, "m15": 0.02, "none": 0.02], conf: 0.96)
            a["click_target"] = self.target("e37", probs: ["e37": 0.58, "none": 0.42], conf: 0.56)
        })
        i.context.elements = [closeWindow]
        i.context.menus = [MenuItem(id: "m15", path: "File › Close Window"), MenuItem(id: "m18", path: "File › Close Tab")]
        let r = Policy.evaluate(i)
        #expect(r.candidate?.action == .menuItem(id: "m18", path: "File › Close Tab"))
        #expect(!r.reasons.contains { $0.name == "intent_merge" }, "a clear intent is no split")
        #expect(r.reasons.contains { $0.note.contains("a tab is not the window") })

        // A real split over a tab: the close button is still not the control that wins.
        var split = i
        split.answers["intent"] = .choice(ChoiceAnswer(choice: "menu_item", probabilities: ["menu_item": 0.46, "click_element": 0.44, "none": 0.1], confidence: 0.3))
        split.answers["click_target"] = target("e37", probs: ["e37": 0.9, "none": 0.1], conf: 0.85)
        let s = Policy.evaluate(split)
        #expect(s.reasons.contains { $0.name == "intent_merge" })
        #expect(s.candidate?.action == .menuItem(id: "m18", path: "File › Close Tab"))
        // With no menu offered, it waits rather than clicking the close button.
        var bare = split
        bare.context.menus = []
        #expect(Policy.evaluate(bare).candidate == nil)

        // Asked for as a click: waits, and says why.
        var click = input("click close tab", isFinal: true, intent: "click_element", mutate: { a in
            a["click_target"] = self.target("e37", probs: ["e37": 0.9, "none": 0.1], conf: 0.85)
        })
        click.context.elements = [closeWindow]
        let c = Policy.evaluate(click)
        #expect(c.candidate == nil)
        #expect(c.summary == "that closes the whole window, not the tab")

        // The window is still the close button's to close.
        var window = click
        window.context.rawTranscript = "close the window"
        #expect(Policy.evaluate(window).candidate?.action == .clickElement(elementId: "e37"))
    }

    @Test func onlyTheWindowsCloseButtonIsBarredAndOnlyForATab() {
        let close = Element(id: "e01", role: "button", text: Element.closeWindowLabel, where: "top-left", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 16, height: 16))
        let page = Element(id: "e02", role: "button", text: "Close", where: "center", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 40, height: 20))
        #expect(Policy.closesMoreThanATab(close, transcript: "close this tab"))
        #expect(Policy.closesMoreThanATab(close, transcript: "Close these Tabs."))
        #expect(!Policy.closesMoreThanATab(close, transcript: "close the window"))
        #expect(!Policy.closesMoreThanATab(close, transcript: "close the table"))
        #expect(!Policy.closesMoreThanATab(page, transcript: "close this tab"), "a page's own Close button is the page's business")
    }

    // MARK: Voice-loop UX pass (review 2026-09-28)

    /// Item 1a: free text commits at the commit window (and not before the 600 ms floor), whatever
    /// `commitWindowMs` decides; this holds for any rule.
    @Test func freeTextWaitsForItsCommitWindowThenActs() {
        func at(_ ms: Double) -> PolicyInput {
            input("google the minnesota vikings", isFinal: false, intent: "web_search", silentMs: ms, site: "google", span: "the minnesota vikings")
        }
        let window = Double(Policy.commitWindowMs(intent: "web_search", input: at(0)))
        let commits = max(window, Double(Config.payloadSilenceMs))
        #expect(Policy.evaluate(at(commits - 50)).outcome.name == "wait")
        let r = Policy.evaluate(at(commits))
        #expect(r.outcome.name == "act")
        #expect(r.candidate?.action.summary == "web_search google 'minnesota vikings'")
    }

    /// Item 1b: the preview is exactly what a waiting clause runs once the words stop; nothing
    /// when it waits on the user or is chatter.
    @Test func previewIsWhatRunsOnceTheWordsStop() {
        let waiting = input("google the minnesota vikings", isFinal: false, intent: "web_search", site: "google", span: "the minnesota vikings")
        #expect(Policy.evaluate(waiting).outcome.name == "wait")
        #expect(Policy.preview(waiting)?.action.summary == "web_search google 'minnesota vikings'")
        #expect(Policy.preview(input("google", isFinal: false, intent: "web_search", site: "google")) == nil, "search for what?")
        #expect(Policy.preview(input("i think we should get lunch", isFinal: false, intent: "none", isCommand: 0.05)) == nil)
    }

    /// Item 2a: "or Sweden" on a Wikipedia page searched Google live on 2026-09-24.
    @Test func aSearchWithNoSiteNamedStaysOnTheSiteInFront() {
        func search(host: String?) -> String? {
            var i = input("search for sweden", isFinal: true, intent: "web_search", span: "sweden")
            i.context.pageHost = host
            return Policy.evaluate(i).candidate?.action.summary
        }
        #expect(search(host: "en.wikipedia.org") == "web_search wikipedia 'sweden'")
        #expect(search(host: "de.wikipedia.org") == "web_search wikipedia 'sweden'", "any language edition")
        #expect(search(host: "youtube.com") == "web_search youtube 'sweden'")
        #expect(search(host: "news.ycombinator.com") == "web_search hacker_news 'sweden'")
        #expect(search(host: "example.com") == "web_search google 'sweden'", "not a catalog site: Google")
        #expect(search(host: nil) == "web_search google 'sweden'")
        var named = input("google sweden", isFinal: true, intent: "web_search", site: "google", span: "sweden")
        named.context.pageHost = "en.wikipedia.org"
        #expect(Policy.evaluate(named).candidate?.action.summary == "web_search google 'sweden'", "a named site wins over the page")
    }

    /// Item 2b: "Wikipedia for Sweden" searched `for Sweden` live on 2026-09-24.
    @Test func theWordJoiningASiteToItsQueryIsDropped() {
        let wikipedia = Config.site(option: "wikipedia")!, google = Config.site(option: "google")!
        #expect(CandidateBuilder.cleanQuery("for Sweden", site: wikipedia).text == "Sweden")
        #expect(CandidateBuilder.cleanQuery("about the vikings", site: google).text == "vikings")
        #expect(CandidateBuilder.cleanQuery("for", site: google).text == "for", "never empties the query")
        let live = input("let's do let's Wikipedia for Sweden", isFinal: true, intent: "web_search", site: "wikipedia", span: "for Sweden")
        #expect(Policy.evaluate(live).candidate?.action.summary == "web_search wikipedia 'Sweden'")
    }

    /// Item 1c: routine decisions say nothing; what needs the user says so.
    @Test func onlyWhatTheUserCanActOnReachesTheStatusLine() {
        let chatter = Policy.evaluate(input("i think we should get lunch", isFinal: false, intent: "none", isCommand: 0.05))
        #expect(Feedback.statusLine(for: chatter.outcome, reasons: chatter.reasons) == nil)
        #expect(!Feedback.engages(chatter.outcome), "chatter keeps the notch folded")
        let speaking = Policy.evaluate(input("google the minnesota", isFinal: false, intent: "web_search", site: "google", span: "the minnesota"))
        #expect(Feedback.statusLine(for: speaking.outcome, reasons: speaking.reasons) == nil, "still talking")
        #expect(Feedback.engages(speaking.outcome))
        let missing = Policy.evaluate(input("google", isFinal: true, intent: "web_search", site: "google"))
        #expect(Feedback.statusLine(for: missing.outcome, reasons: missing.reasons) == "search for what?")
        #expect(Feedback.statusLine(for: .ignore(reason: "denied: element 'Delete'"), reasons: []) == "won't do that: element 'Delete'")
        #expect(Feedback.statusLine(for: .act(candidateId: "c"), reasons: []) == "", "an act clears it; the chip carries it")
    }

    /// Item 3d: examples follow the app and the page in front.
    @Test func suggestionsFollowTheAppAndPageInFront() {
        #expect(Suggestions.phrases(bundleId: "com.apple.Notes", pageHost: nil).first == "create a new note")
        #expect(Suggestions.phrases(bundleId: "com.google.Chrome", pageHost: "en.wikipedia.org").first == "search for Norbert Wiener")
        #expect(Suggestions.phrases(bundleId: "com.google.Chrome", pageHost: "www.google.com").first == "google norbert wiener")
        #expect(Suggestions.phrases(bundleId: "com.example.other", pageHost: nil).contains("open chrome"))
        #expect(Suggestions.phrases(bundleId: nil, pageHost: nil).count <= 4)
    }

    /// The commit rule: free text commits at 600 ms of silence, everything else at 900.
    @Test func freeTextCommitsSoonerThanOtherCommands() {
        let search = input("google the minnesota vikings", isFinal: false, intent: "web_search", site: "google", span: "the minnesota vikings")
        #expect(Policy.commitWindowMs(intent: "web_search", input: search) == Config.payloadSilenceMs)
        #expect(Policy.commitWindowMs(intent: "type_text", input: search) == Config.payloadSilenceMs)
        #expect(Policy.commitWindowMs(intent: "click_element", input: search) == Config.silenceCompleteMs)
        #expect(Policy.commitWindowMs(intent: "new_note", input: search) == Config.silenceCompleteMs)
        let at650 = input("google the minnesota vikings", isFinal: false, intent: "web_search", silentMs: 650, site: "google", span: "the minnesota vikings")
        #expect(Policy.evaluate(at650).outcome.name == "act")
    }

    /// The pause in "let's search Wikipedia for | Michael Jordan" (live, 2026-09-22): the span was
    /// the site's own name, which at a 600 ms window would have searched Wikipedia for "Wikipedia".
    @Test func onlyTheSitesNameIsNoQuery() {
        let paused = input("let's search Wikipedia for", isFinal: false, intent: "web_search", silentMs: 700, site: "wikipedia", span: "Wikipedia")
        #expect(paused.spans.payload(text: "Wikipedia") != nil, "the span Jev picked live is one the code offers")
        #expect(Policy.evaluate(paused).outcome == .wait(reason: "search for what?", retryInMs: nil))
        #expect(CandidateBuilder.cleanQuery("Wikipedia", site: Config.site(option: "wikipedia")!).text == "")
    }

    /// A site taken from the page, not named: its words stay in the query.
    @Test func aPageSiteKeepsItsOwnWordsInTheQuery() {
        var i = input("who founded wikipedia", isFinal: true, intent: "web_search", span: "who founded wikipedia")
        i.context.pageHost = "en.wikipedia.org"
        #expect(Policy.evaluate(i).candidate?.action.summary == "web_search wikipedia 'who founded wikipedia'")
    }

    /// Clicks read by their label in the overlay and in a spoken confirmation; logs keep the id.
    @Test func clicksAreNamedByTheirLabel() {
        let archive = Candidate(id: "c", snapshotId: "s", action: .clickElement(elementId: "e07"), targetElementId: "e07", expectedPostcondition: "", label: "Archive")
        #expect(archive.humanLabel == "Click “Archive”")
        #expect(archive.spokenLabel == "click Archive")
        #expect(archive.summary == "click_element e07", "logs, replay, and the state sent to Jev keep the machine form")
        #expect(Candidate(id: "c", snapshotId: "s", action: .pressEnter, expectedPostcondition: "").spokenLabel == "press Return")
        #expect(Candidate(id: "c", snapshotId: "s", action: .clickElement(elementId: "e07"), expectedPostcondition: "").humanLabel == "Click e07",
                "no label known: the id is all there is")
    }

    /// Item 3d: only actions with a safe inverse can be undone.
    @Test func undoIsOfferedOnlyWhereItIsSafe() {
        let search = Action.webSearch(url: "https://www.google.com/search?q=x", query: "x", site: "google")
        #expect(Undo.inverse(of: search, detail: Undo.navigatedInPlace) == .goBack)
        #expect(Undo.inverse(of: search, detail: "opened") == nil, "a new tab: Back would not undo it")
        #expect(Undo.inverse(of: .typeText(text: "hi"), detail: "ok") == .menuItem(id: "undo", path: "Edit › Undo"))
        #expect(Undo.inverse(of: .clickElement(elementId: "e01"), detail: "ok") == nil)
        #expect(Undo.inverse(of: .openApp(bundleId: "com.apple.Notes", name: "Notes"), detail: "activated") == nil)
    }
}
