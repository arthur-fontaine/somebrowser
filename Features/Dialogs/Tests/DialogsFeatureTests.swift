import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureDialogs

@MainActor
struct DialogsFeatureTests {
    func harness() throws -> TestHarness { try TestHarness(features: [DialogsFeature.self], manifestDirectory: #filePath) }

    func ask(_ kind: PageDialog.Kind, on tab: BrowserTab, in h: TestHarness) -> () -> PageDialog.Answer? {
        var answer: PageDialog.Answer?
        h.runtime.engine.hooks.pageDialog?(PageDialog(kind: kind, message: "Sure?", origin: tab.url, tab: h.fakeTab(tab))) { answer = $0 }
        return { answer }
    }

    /// The browser shows pages' dialogs (so engines don't show theirs), over the selected page, and answers them.
    @Test func dialogsShowOverTheirPageAndAnswer() throws {
        let h = try harness()
        let tab = h.openTab("https://a.example")
        let confirm = ask(.confirm, on: tab, in: h)
        #expect(h.runtime.commands.canRun("dialogs.accept"))
        try h.run("dialogs.accept")
        #expect(confirm() == PageDialog.Answer(accepted: true))
        let prompt = ask(.prompt(defaultText: "hi"), on: tab, in: h)
        try h.run("dialogs.accept", arguments: ["text": "typed"])
        #expect(prompt()?.text == "typed")
        let signIn = ask(.signIn(host: "a.example", realm: "Admin", isProxy: false), on: tab, in: h)
        try h.run("dialogs.accept", arguments: ["username": "me", "password": "pw"])
        #expect(signIn() == PageDialog.Answer(accepted: true, text: "me", password: "pw"))
        let leave = ask(.leavePage(isReload: false), on: tab, in: h)
        try h.run("dialogs.cancel")
        #expect(leave()?.accepted == false)
    }

    /// A background tab's dialog waits for its tab; a closed tab's dialog is answered no.
    @Test func dialogsWaitForTheirTabAndEndWithIt() throws {
        let h = try harness()
        let background = h.openTab("https://a.example")
        let front = h.openTab("https://b.example")
        let waiting = ask(.alert, on: background, in: h)
        #expect(!h.runtime.commands.canRun("dialogs.accept"))
        h.runtime.select(background.id, in: h.window)
        #expect(h.runtime.commands.canRun("dialogs.accept"))
        let orphan = ask(.confirm, on: front, in: h)
        h.runtime.close(front.id)
        #expect(orphan()?.accepted == false)
        #expect(waiting() == nil)
    }
}
