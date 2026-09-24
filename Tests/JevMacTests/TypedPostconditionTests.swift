import Testing
@testable import JevMac
@testable import JevCore

@Suite struct TypedPostconditionTests {
    let ex = MacExecutor(mode: .dryRun)

    @Test func insertNeedsTheTextAndAChange() async {
        #expect(await ex.typed("groceries", placement: .insert, before: "", now: "groceries"))
        #expect(await ex.typed("groceries", placement: .insert, before: "shopping", now: "shoppinggroceries"), "an append is a valid insert")
        #expect(!(await ex.typed("groceries", placement: .insert, before: "groceries", now: "groceries")), "nothing changed")
    }

    @Test func replacingTheTitleNeedsTheOldTitleGone() async {
        // The 2026-09-20 report: keystrokes landed after the existing title and the insert test passed.
        #expect(!(await ex.typed("groceries", placement: .replaceTitle, before: "shopping\nmilk", now: "shoppinggroceries\nmilk")))
        #expect(await ex.typed("groceries", placement: .replaceTitle, before: "shopping\nmilk", now: "groceries\nmilk"))
        #expect(await ex.typed("groceries", placement: .replaceTitle, before: "", now: "groceries"), "an empty note: the title is the first line")
        #expect(!(await ex.typed("groceries", placement: .replaceAll, before: "shopping\nmilk", now: "groceries\nmilk")), "the body survived a whole-field replacement")
        #expect(await ex.typed("groceries", placement: .replaceAll, before: "shopping\nmilk", now: "groceries\n"))
    }

    @Test func firstLineStopsAtAnyNewline() {
        #expect(MacExecutor.firstLine("shopping\nmilk") == "shopping")
        #expect(MacExecutor.firstLine("shopping\r\nmilk") == "shopping")
        #expect(MacExecutor.firstLine("shopping") == "shopping")
        #expect(MacExecutor.firstLine("") == "")
    }
}
