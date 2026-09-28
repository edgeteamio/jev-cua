import Foundation
import Testing
@testable import JevCore

/// Serving Jev through Vercel AI Gateway's TypeSafe-compatible API: the endpoint choice, the URLs,
/// and the gateway's response and error shapes (vercel.com/docs/ai-gateway/sdks-and-apis/typesafe).
@Suite struct JevEndpointTests {
    @Test func theDirectEndpointIsTheDefault() throws {
        for env in [[:], ["JEV_ENDPOINT": ""], ["JEV_ENDPOINT": "typesafe"]] as [[String: String]] {
            let e = try JevEndpoint.from(environment: env)
            #expect(e == .typesafe)
            #expect(e.model == Config.model)
            #expect(e.keyName == "TYPESAFE_API_KEY")
            #expect(e.pinned)
        }
    }

    @Test func theGatewayEndpointUsesItsBaseURLKeyAndModel() throws {
        let e = try JevEndpoint.from(environment: ["JEV_ENDPOINT": "gateway"])
        #expect(e.kind == .gateway)
        #expect(e.baseURL.absoluteString == "https://ai-gateway.vercel.sh/typesafe")
        #expect(e.model == "typesafe-ai/jev")
        #expect(e.keyName == "AI_GATEWAY_API_KEY")
        #expect(!e.pinned, "the gateway ID follows TypeSafe's latest release")
        #expect(try JevEndpoint.from(environment: ["JEV_ENDPOINT": " Vercel "]).kind == .gateway)
        #expect(try JevEndpoint.from(environment: ["JEV_ENDPOINT": "ai-gateway"]).kind == .gateway)
    }

    @Test func aGatewayModelCanBeChosenAndAVersionCountsAsPinned() throws {
        let e = try JevEndpoint.from(environment: ["JEV_ENDPOINT": "gateway", "JEV_GATEWAY_MODEL": "typesafe-ai/jev-1.13.0"])
        #expect(e.model == "typesafe-ai/jev-1.13.0")
        #expect(e.pinned)
    }

    @Test func anOIDCTokenAuthenticatesWhenThereIsNoKey() throws {
        let oidc = try JevEndpoint.from(environment: ["JEV_ENDPOINT": "gateway", "VERCEL_OIDC_TOKEN": "t"])
        #expect(oidc.keyName == "VERCEL_OIDC_TOKEN")
        let both = try JevEndpoint.from(environment: ["JEV_ENDPOINT": "gateway", "VERCEL_OIDC_TOKEN": "t", "AI_GATEWAY_API_KEY": "k"])
        #expect(both.keyName == "AI_GATEWAY_API_KEY", "an explicit key wins")
    }

    @Test func anUnknownEndpointIsAnErrorNotASilentDefault() {
        #expect(throws: JevEndpoint.EndpointError.self) { try JevEndpoint.from(environment: ["JEV_ENDPOINT": "openai"]) }
    }

    @Test func theClientPostsToTheGatewaysTypeSafePath() throws {
        let gateway = try JevEndpoint.from(environment: ["JEV_ENDPOINT": "gateway"])
        let client = try JevClient(endpoint: gateway, apiKey: "test-key")
        #expect(client.baseURL.appending(path: "/v1/systemone").absoluteString == "https://ai-gateway.vercel.sh/typesafe/v1/systemone")
        #expect(client.model == "typesafe-ai/jev")
    }

    @Test func aMissingCredentialIsNamed() {
        let unset = JevEndpoint(kind: .gateway, baseURL: Config.gatewayBaseURL, model: Config.gatewayModel, keyName: "JEV_TEST_UNSET_\(UUID().uuidString.prefix(8))")
        #expect(throws: JevError.self) { try JevClient(endpoint: unset) }
        do { _ = try JevClient(endpoint: unset) } catch let e as JevError {
            #expect(e.description.hasPrefix(unset.keyName + " is not set"))
            #expect(e.isOutage)
        } catch { Issue.record("unexpected \(error)") }
    }

    /// Answers cached through one endpoint are never served for the other: the model is part of
    /// the request, and so of the cache key.
    @Test func theTwoEndpointsNeverShareCachedAnswers() {
        let q: [String: Question] = ["x": .noul("Is it?")]
        let direct = JevRequest(state: ["t": "a"], model: Config.model, questions: q).cacheKey()
        let gateway = JevRequest(state: ["t": "a"], model: Config.gatewayModel, questions: q).cacheKey()
        #expect(direct != gateway)
    }

    /// The gateway's documented response: TypeSafe's fields plus routing and cost metadata.
    @Test func aGatewayResponseDecodesAndNamesItsGeneration() throws {
        let body = #"""
        {"model": "typesafe-ai/jev", "answers": {"refund": {"type": "noul", "noul": 0.98}},
         "usage": {"input_tokens": 275, "output_tokens": 20},
         "provider_metadata": {"gateway": {"routing": {"originalModelId": "typesafe-ai/jev", "finalProvider": "typesafe-ai"},
                                           "cost": "0.00001155", "generationId": "gen_01abc"}}}
        """#
        let resp = try JSONDecoder().decode(JevResponse.self, from: Data(body.utf8))
        #expect(resp.answers["refund"]?.noul == 0.98)
        #expect(resp.usage.inputTokens == 275)
        #expect(JevClient.gatewayGenerationId(Data(body.utf8)) == "gen_01abc")
        #expect(JevClient.gatewayGenerationId(Data(#"{"model": "jev-1.13.0", "answers": {}}"#.utf8)) == nil)
    }

    @Test func eitherModelListShapeReads() throws {
        let typesafe = #"{"models": [{"name": "jev-latest", "description": "latest stable", "release_date": "2026-09-01"}]}"#
        #expect(try JevClient.decodeModels(Data(typesafe.utf8)).map(\.name) == ["jev-latest"])
        let listed = #"{"object": "list", "data": [{"id": "typesafe-ai/jev", "description": "System One evaluation model"}]}"#
        #expect(try JevClient.decodeModels(Data(listed.utf8)).map(\.name) == ["typesafe-ai/jev"])
    }

    /// AI Gateway's spend errors (its setup guide's error table) read as outages with a reason.
    @Test func gatewaySpendErrorsAreOutagesWithTheirReason() {
        let funds = JevError.http(status: 402, body: #"{"error_type": "insufficient_funds", "message": "no credits"}"#)
        #expect(funds.isOutage)
        #expect(funds.outageSummary == "AI Gateway credits used up (HTTP 402)")
        #expect(JevError.http(status: 402, body: #"{"error_type": "quota_for_entity_exceeded"}"#).outageSummary == "AI Gateway budget exhausted (HTTP 402)")
        #expect(JevError.http(status: 403, body: #"{"error_type": "customer_verification_required"}"#).outageSummary == "AI Gateway needs a payment method (HTTP 403)")
        #expect(JevError.http(status: 401, body: "").outageSummary == "API key rejected (HTTP 401)")
    }
}
