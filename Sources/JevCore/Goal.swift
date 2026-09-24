import Foundation

// Goal mode (plan Phase 6). A typed goal runs a bounded observe → decide → act → verify loop.
// Jev supplies the per-step judgments; code owns the loop, the budgets, and the stop rules.
// Escalation (planner, writer) sits behind `Escalating` with call and cost budgets and is
// visible in the trace; Jev still decides every action.

public struct TaskSpec: Codable, Sendable, Equatable {
    public var id: String
    public var goal: String
    public var subgoals: [String]
    public var constraints: [String]
    public var stepBudget: Int
    public var timeBudgetS: Double
    public var escalationBudget: Int

    public init(goal: String, subgoals: [String] = [], constraints: [String] = [], stepBudget: Int = Config.Goal.stepBudget,
                timeBudgetS: Double = Config.Goal.timeBudgetS, escalationBudget: Int = Config.Goal.escalationBudget) {
        self.id = Ident.make("t"); self.goal = goal; self.subgoals = subgoals; self.constraints = constraints
        self.stepBudget = stepBudget; self.timeBudgetS = timeBudgetS; self.escalationBudget = escalationBudget
    }
}

/// One loop iteration, as logged and shown.
public struct GoalStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case act, reobserve, abstain, achieved, blocked, clarify, stop }
    public var index: Int
    public var subgoal: String
    public var kind: Kind
    public var summary: String
    public var action: String?
    public var verification: String?
    public var reasons: [GateReason]
    public var latencyMs: Double
    public var inputTokens: Int
    public var escalation: String?
}

public struct GoalResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case achieved, blocked, needsClarification, budgetExhausted, abstained, cancelled, failed }
    public var task: TaskSpec
    public var outcome: Outcome
    public var detail: String
    public var steps: [GoalStep]
    public var escalations: Int
    public var costUSD: Double
    public var elapsedS: Double
    /// For a goal that asks a question: the writer's answer, withheld unless the loop's last
    /// verification was a success (plan Phase 6 writer rules).
    public var answer: String?
}

/// Stronger models, behind budgets. Each call is visible in the trace. Nil results mean
/// "unavailable" and the runner carries on with Jev alone.
public protocol Escalating: Sendable {
    var name: String { get }
    /// Split a compound goal into ordered subgoals, each with what would prove it done.
    func plan(goal: String) async throws -> [String]
    /// Draft the text a field needs; the reply must be exactly `{"text": "..."}` or nothing is typed.
    func write(goal: String, field: FocusedField?, app: String, history: [String]) async throws -> String?
    /// Compose the answer to an information goal from what was observed.
    func compose(goal: String, observations: [String], history: [String]) async throws -> String?
}

extension Config {
    public enum Goal {
        public static let stepBudget = 12
        public static let timeBudgetS = 90.0
        public static let escalationBudget = 4
        public static let achievedThreshold = 0.75
        public static let blockedThreshold = 0.70
        public static let reobserveThreshold = 0.70
        public static let nextActionConfidence = 0.50
        public static let missingThreshold = 0.75
        public static let maxConsecutiveNoOps = 2
        public static let maxReobserves = 3
        public static let reobserveDelayMs = 600
    }
}
