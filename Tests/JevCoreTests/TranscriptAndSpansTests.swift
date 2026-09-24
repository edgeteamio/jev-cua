import Testing
@testable import JevCore

@Suite struct TranscriptTests {
    @Test func normalizesCaseAndPunctuation() {
        #expect(Transcript.normalize("Open the Notes app.") == "open the notes app")
        #expect(Transcript.normalize("  Let's   Google search, Tom Cruise!  ") == "let's google search tom cruise")
        #expect(Transcript.normalize("Click on the 1st link.") == "click on the 1st link")
    }

    @Test func keepsTailWhenTooLong() {
        let raw = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let n = Transcript.normalize(raw, maxChars: 30)
        #expect(n.count <= 30)
        #expect(n.hasSuffix("word199"))
    }

    @Test func stripsExactConsumedPrefix() {
        #expect(Transcript.stripConsumed(raw: "open the notes app and create a new note", consumedPrefix: "open the notes app") == "create a new note")
        #expect(Transcript.stripConsumed(raw: "Open the Notes app.", consumedPrefix: "open the notes app") == "")
        #expect(Transcript.stripConsumed(raw: "open notes", consumedPrefix: "") == "open notes")
    }

    @Test func toleratesRewrittenEarlierWords() {
        // The recognizer rewrote "all right right click on that first link" to "right click on that first link".
        let r = Transcript.stripConsumed(raw: "right click on that first link let's open wikipedia",
                                         consumedPrefix: "all right right click on that first link")
        #expect(r == "let's open wikipedia")
    }

    @Test func rejectsUnalignedRevision() {
        #expect(Transcript.stripConsumed(raw: "google search tom cruise", consumedPrefix: "open the notes app") == nil)
    }
}

@Suite struct SpansTests {
    @Test func triggerRemaindersComeFirstWithFillerVariant() {
        let s = Spans.extract(from: "google search norbert wiener please")
        #expect(s.payload.first?.text == "norbert wiener", "the filler-stripped remainder leads")
        #expect(s.payload[1].text == "norbert wiener please")
        #expect(s.payload.count <= 32)
    }

    @Test func titleTriggerBeatsSay() {
        let s = Spans.extract(from: "make the title say hello there")
        #expect(s.payload.first?.text == "hello", "\"there\" is a trailing filler; the full remainder is still offered")
        #expect(s.payload[1].text == "hello there")
    }

    @Test func spansAreVerbatimAndRangedIntoRawTokens() {
        let raw = "Type Hello, World! into it"
        let s = Spans.extract(from: raw)
        let first = s.payload.first { $0.text == "Hello, World! into it" }
        #expect(first != nil)
        let tokens = Transcript.tokens(raw)
        #expect(first.map { tokens[$0.range].joined(separator: " ") } == "Hello, World! into it")
        #expect(s.payload.contains { $0.text == "Hello, World" })
    }

    @Test func capHoldsAndSuffixesPrecedeInnerSpans() {
        let raw = (1...40).map { "w\($0)" }.joined(separator: " ")
        let s = Spans.extract(from: raw)
        #expect(s.payload.count == 32)
        #expect(s.payload[0].text == raw)
        #expect(s.payload[1].text == (2...40).map { "w\($0)" }.joined(separator: " "))
    }

    @Test func urlSpans() {
        #expect(Spans.toHttpURL("x dot com") == "https://x.com/")
        #expect(Spans.toHttpURL("x.com") == "https://x.com/")
        #expect(Spans.toHttpURL("x dotcom") == "https://x.com/")
        #expect(Spans.toHttpURL("github dot com slash trycua") == "https://github.com/trycua")
        #expect(Spans.toHttpURL("wikipedia") == nil)
        let s = Spans.extract(from: "Open x dotcom.")
        #expect(s.urls.first?.text == "x dotcom")
        let t = Spans.extract(from: "open x dot com now")
        #expect(t.urls.first?.text == "x dot com")
    }

    @Test func numbersAndKillPhrases() {
        #expect(Spans.numberWord("first") == 1)
        #expect(Spans.numberWord("two") == 2)
        #expect(Spans.numberWord("3rd") == 3)
        #expect(Spans.numberWord("9") == 9)
        #expect(Spans.numberWord("ten") == nil)
        #expect(Spans.isKillPhrase("Stop."))
        #expect(Spans.isKillPhrase("never mind"))
        #expect(!Spans.isKillPhrase("stop the music"))
    }

    @Test func stripConsumedDropsContinuationFillers() {
        #expect(Transcript.stripConsumed(raw: "open the notes app and create a new note", consumedPrefix: "open the notes") == "create a new note")
        #expect(Transcript.stripConsumed(raw: "open chrome then scroll down", consumedPrefix: "open chrome") == "scroll down")
        #expect(Transcript.stripConsumed(raw: "open chrome and then please scroll down", consumedPrefix: "open chrome") == "scroll down")
        #expect(Transcript.stripConsumed(raw: "open chrome and", consumedPrefix: "open chrome") == "")
        #expect(Transcript.stripConsumed(raw: "open the app store", consumedPrefix: "") == "open the app store", "no consumed prefix: untouched")
    }

    @Test func gluedDomainsAndDottedTokens() {
        #expect(Transcript.tokens("openx.com") == ["open", "x.com"])
        #expect(Transcript.tokens("open x.com") == ["open", "x.com"])
        #expect(Transcript.tokens("opening the door") == ["opening", "the", "door"], "no domain: untouched")
        #expect(Transcript.normalize("Open x.com!") == "open x.com")
        #expect(Transcript.normalize("Hello. World.") == "hello world")
        let spans = Spans.extract(from: "openx.com")
        #expect(spans.urls.map(\.text) == ["x.com"])
        #expect(Spans.toHttpURL("x.com") == "https://x.com/")
        #expect(Spans.extract(from: "go to github.com please").urls.map(\.text) == ["github.com"])
    }
}
