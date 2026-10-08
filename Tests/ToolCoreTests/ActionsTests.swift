import Foundation
import XCTest
@testable import ToolCore

@MainActor
final class ActionsTests: XCTestCase {
    /// Fills {{name}} from the values and {{last}}, as the app's filling does.
    func fill(_ text: String, _ last: String?, _ values: [String: String]) -> String {
        var out = text.replacingOccurrences(of: "{{last}}", with: last ?? "")
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }

    /// Runs `id`, each step answering "<kind>:<text>" (a step whose text is "fail" fails), and
    /// keeps the steps it was asked to do.
    func run(_ id: String, _ book: ActionBook, arguments: [ActionArgument] = [], context: [String: String] = [:],
             last: String? = nil) async -> (ActionRunner.Outcome, [String]) {
        var done: [String] = []
        let outcome = await ActionRunner.run(id, arguments: arguments, context: context, last: last, book: book,
                                             fill: fill) { step, text, _ in
            done.append(text)
            if text == "fail" { return .failed("it broke") }
            return ActionRunner.Outcome(ok: true, output: "\(step.kind.rawValue):\(text)", tools: [step.kind.rawValue],
                                        fresh: step.kind.hasResult)
        }
        return (outcome, done)
    }

    func testStepsRunInTurnEachGettingTheLast() async {
        let a = SavedAction(name: "A", steps: [ActionStep(kind: .askModel, text: "hello {{last}}"),
                                                ActionStep(kind: .speak, text: "said {{last}}")])
        let (out, done) = await run(a.id, ActionBook(actions: [a]), last: "before")
        XCTAssertEqual(done, ["hello before", "said askModel:hello before"])
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.output, "speak:said askModel:hello before")
        XCTAssertEqual(out.tools, ["askModel", "speak"])
        XCTAssertFalse(out.fresh)   // the last step said it already
    }

    func testStepsTurnedOffAreSkipped() async {
        let a = SavedAction(name: "A", steps: [ActionStep(kind: .remind, text: "one"),
                                                ActionStep(kind: .speak, text: "two", off: true),
                                                ActionStep(kind: .remind, text: "three {{last}}")])
        let (out, done) = await run(a.id, ActionBook(actions: [a]))
        XCTAssertEqual(done, ["one", "three remind:one"])
        XCTAssertEqual(out.output, "remind:three remind:one")
        XCTAssertEqual(a.summary, "Remind me, then Remind me (1 off)")
        let none = SavedAction(name: "None", steps: [ActionStep(kind: .remind, off: true)])
        let (failed, nothing) = await run(none.id, ActionBook(actions: [none]))
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testAWaitPassesTheLastOnThrough() async {
        let a = SavedAction(name: "A", steps: [ActionStep(kind: .askModel, text: "q"),
                                                ActionStep(kind: .wait, target: "2"),
                                                ActionStep(kind: .remind, text: "got {{last}}"),
                                                ActionStep(kind: .wait, target: "1")])
        let (out, done) = await run(a.id, ActionBook(actions: [a]))
        XCTAssertEqual(done, ["q", "", "got askModel:q", ""])
        XCTAssertEqual(out.output, "remind:got askModel:q")
        XCTAssertFalse(out.fresh)
    }

    func testWaitAndNoteTargets() {
        XCTAssertEqual(ActionStep(kind: .wait, target: "90").seconds, 90)
        XCTAssertEqual(ActionStep(kind: .wait, target: "soon").seconds, 5)
        XCTAssertEqual(ActionStep(kind: .wait, target: "99999").seconds, 3600)
        XCTAssertEqual(ActionStep.span(90), "1 minute 30 seconds")
        XCTAssertEqual(ActionStep.span(1), "1 second")
        let link = NoteLink(board: "goals", box: 3)
        XCTAssertEqual(ActionStep(kind: .addToNote, target: ActionStep.target(link)).note, link)
        XCTAssertNil(ActionStep(kind: .addToNote, target: "goals").note)
        XCTAssertNil(ActionStep(kind: .addToNote, target: "#2").note)
    }

    func testOldStepsLoadTurnedOn() throws {
        let json = #"{"id": "s", "kind": "remind", "text": "hi"}"#
        let step = try JSONDecoder().decode(ActionStep.self, from: Data(json.utf8))
        XCTAssertFalse(step.off)
        let again = try JSONDecoder().decode(ActionStep.self, from: JSONEncoder().encode(ActionStep(kind: .wait, target: "3", off: true)))
        XCTAssertTrue(again.off)
        XCTAssertEqual(again.kind, .wait)
    }

    func testArgumentsTakeTheirDefaultsWhenNotGiven() async {
        let a = SavedAction(name: "Greet", parameters: [ActionArgument(name: "who", value: "you"), ActionArgument(name: "how", value: "Hi")],
                            steps: [ActionStep(kind: .remind, text: "{{how}} {{who}} at {{time}}")])
        let book = ActionBook(actions: [a])
        let (_, plain) = await run(a.id, book, context: ["time": "9:00"])
        XCTAssertEqual(plain, ["Hi you at 9:00"])
        let (_, given) = await run(a.id, book, arguments: [ActionArgument(name: "who", value: "Sam"), ActionArgument(name: "how", value: "")],
                                   context: ["time": "9:00"])
        XCTAssertEqual(given, ["Hi Sam at 9:00"])
        XCTAssertEqual(a.values(given: [ActionArgument(name: "other", value: "x")]), ["who": "you", "how": "Hi"])
    }

    func testAnActionRunsOthersWithArgumentsOfItsOwn() async {
        let say = SavedAction(name: "Say", parameters: [ActionArgument(name: "message", value: "nothing")],
                              steps: [ActionStep(kind: .speak, text: "{{message}}")])
        let shout = SavedAction(name: "Shout", parameters: [ActionArgument(name: "word")],
                                steps: [ActionStep(kind: .remind, text: "{{word}}!")])
        let both = SavedAction(name: "Both", parameters: [ActionArgument(name: "name", value: "Sam")], steps: [
            ActionStep(kind: .runAction, target: say.id, arguments: [ActionArgument(name: "message", value: "hello {{name}}")]),
            ActionStep(kind: .runAction, target: shout.id, arguments: [ActionArgument(name: "word", value: "{{last}}")]),
            ActionStep(kind: .runAction, target: say.id),
        ])
        let (out, done) = await run(both.id, ActionBook(actions: [say, shout, both]))
        XCTAssertTrue(out.ok)
        // A called action sees only what it's given: not the caller's own arguments.
        XCTAssertEqual(done, ["hello Sam", "speak:hello Sam!", "nothing"])
        XCTAssertEqual(out.output, "speak:nothing")
    }

    func testAFailingStepStopsTheRest() async {
        let a = SavedAction(name: "A", steps: [ActionStep(kind: .remind, text: "one"), ActionStep(kind: .shortcut, text: "fail"),
                                                ActionStep(kind: .speak, text: "three")])
        let (out, done) = await run(a.id, ActionBook(actions: [a]))
        XCTAssertFalse(out.ok)
        XCTAssertEqual(done, ["one", "fail"])
        XCTAssertEqual(out.output, "A, step 2 (Shortcut): it broke")
    }

    func testAnActionThatComesRoundToItselfFails() async {
        var a = SavedAction(id: "a", name: "A", steps: [])
        let b = SavedAction(id: "b", name: "B", steps: [ActionStep(kind: .runAction, target: "a")])
        a.steps = [ActionStep(kind: .remind, text: "once"), ActionStep(kind: .runAction, target: "b")]
        let book = ActionBook(actions: [a, b])
        XCTAssertEqual(book.loop(from: "a"), ["A", "B", "A"])
        XCTAssertNil(ActionBook(actions: [b]).loop(from: "b"))
        let (out, done) = await run("a", book)
        XCTAssertFalse(out.ok)
        XCTAssertEqual(done, ["once"])
        XCTAssertTrue(out.output.contains("comes round to itself: A → B → A"), out.output)
        XCTAssertEqual(book.callers(of: "a"), ["B"])
    }

    func testMissingOrEmptyActionsFail() async {
        let empty = SavedAction(name: "Empty")
        let (none, _) = await run("gone", ActionBook())
        XCTAssertFalse(none.ok)
        let (nothing, _) = await run(empty.id, ActionBook(actions: [empty]))
        XCTAssertFalse(nothing.ok)
        XCTAssertTrue(nothing.output.contains("no steps"))
    }

    func testOldJobsAreSeparatedIntoActions() throws {
        let json = #"""
        {"jobs":[{"id":"j","name":"Water","action":"speak","text":"Drink {{time}}","when":{"kind":"every","minutes":30}},
                 {"id":"builtin-day-chime","name":"Day chime","action":"chime","target":"day","builtin":"day-chime"}],"runs":[]}
        """#
        var book = try JSONDecoder().decode(ScheduleBook.self, from: Data(json.utf8))
        var actions = ActionBook()
        actions.ensureBuiltins()
        XCTAssertTrue(book.separate(into: &actions))
        book.ensureBuiltins()
        let water = try XCTUnwrap(book.jobs.first { $0.id == "j" })
        let made = try XCTUnwrap(actions.action(water.actionID))
        XCTAssertEqual(made.name, "Water")
        XCTAssertEqual(made.steps.map(\.kind), [.speak])
        XCTAssertEqual(made.steps.first?.text, "Drink {{time}}")
        XCTAssertNil(water.inline)
        XCTAssertEqual(book.jobs.first { $0.builtin == "day-chime" }?.actionID, SavedAction.Builtin.dayChime.id)
        XCTAssertEqual(book.jobs.first { $0.builtin == "night-chime" }?.actionID, SavedAction.Builtin.nightWatch.id)
        XCTAssertEqual(actions.actions.count, 4)   // the three built in, and Water's
        XCTAssertFalse(book.separate(into: &actions))
        // Saved and read back: the job keeps its action, and nothing of its own.
        let back = try JSONDecoder().decode(ScheduleBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(back, book)
        let again = try JSONDecoder().decode(ActionBook.self, from: JSONEncoder().encode(actions))
        XCTAssertEqual(again, actions)
    }

    func testBuiltinActionsComeBackAsTheyWere() {
        var book = ActionBook(actions: [SavedAction(id: SavedAction.Builtin.dayChime.id, name: "Changed", steps: [], builtin: "day-chime")])
        book.ensureBuiltins()
        XCTAssertEqual(book.actions.map(\.name), ["Day chime", "Night watch", "Send to dashboard"])
        XCTAssertEqual(book.actions.filter(\.isChime).count, 2)
        XCTAssertEqual(book.actions.last?.steps.map(\.kind), [.dashboard])
    }

    func testTheDashboardKeepsItsAddressAndStepsUseIt() throws {
        var book = ActionBook()
        book.ensureBuiltins()
        let mine = ActionStep(kind: .dashboard)
        XCTAssertNil(book.dashboardAddress(for: mine))
        book.setDashboard(url: " https://dash.example.dev/api/signals ", secret: "shh", note: "{{event}}")
        // Read back and made sure of again (as on every start): the address stays.
        book = try JSONDecoder().decode(ActionBook.self, from: JSONEncoder().encode(book))
        book.ensureBuiltins()
        XCTAssertEqual(book.dashboard?.target, "https://dash.example.dev/api/signals")
        XCTAssertEqual(book.dashboard?.text, "{{event}}")
        // A step with no address of its own sends to the built-in's, with its secret.
        let shared = try XCTUnwrap(book.dashboardAddress(for: mine))
        XCTAssertEqual(shared.url.host, "dash.example.dev")
        XCTAssertEqual(shared.secret, "shh")
        // One with its own uses that (and its own secret).
        let own = try XCTUnwrap(book.dashboardAddress(for: ActionStep(kind: .dashboard, target: "http://other.test/x", secret: "")))
        XCTAssertEqual(own.url.host, "other.test")
        XCTAssertEqual(own.secret, "")
        XCTAssertNil(book.dashboardAddress(for: ActionStep(kind: .dashboard, target: "not an address")))
        XCTAssertTrue(ActionStep.Kind.dashboard.hasResult)
        XCTAssertTrue(ActionStep(kind: .dashboard).doing { _ in nil }.contains("the dashboard"))
    }

    func testArgumentNamesAreCleanedAndKeptForTheForm() {
        XCTAssertEqual(ActionArgument.clean(" Who Is It? "), "who_is_it")
        let a = SavedAction(parameters: [ActionArgument(name: "who"), ActionArgument(name: "when", value: "now")])
        XCTAssertEqual(a.arguments(keeping: [ActionArgument(name: "when", value: "later"), ActionArgument(name: "gone", value: "x")]),
                       [ActionArgument(name: "who"), ActionArgument(name: "when", value: "later")])
    }

    func testTheExamplesCallEachOther() async {
        let book = ActionBook(actions: ActionBook.examples)
        let water = try! XCTUnwrap(book.actions.first { $0.name == "Drink some water" })
        let (out, done) = await run(water.id, book, context: ["time": "10:00"])
        XCTAssertTrue(out.ok)
        XCTAssertEqual(done, ["Drink some water (10:00).", "Drink some water (10:00)."])
    }
}
