import Testing
@testable import JevCore

@Suite struct EnvTests {
    @Test func parsesKeyValueLines() {
        let text = """
        # comment
        TYPESAFE_API_KEY=abc123
        export OTHER="quoted value"
        SINGLE='x'
        TRAILING=value # a comment
        BAD LINE
        =nokey
        """
        let env = Env.parse(text)
        #expect(env["TYPESAFE_API_KEY"] == "abc123")
        #expect(env["OTHER"] == "quoted value")
        #expect(env["SINGLE"] == "x")
        #expect(env["TRAILING"] == "value")
        #expect(env.count == 4)
    }

    @Test func keepsHashInsideQuotedValue() {
        let env = Env.parse("K=\"a#b\"")
        #expect(env["K"] == "a#b")
    }
}
