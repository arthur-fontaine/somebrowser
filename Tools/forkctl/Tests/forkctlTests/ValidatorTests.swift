import Testing
@testable import forkctl

@Test func shortcutsNormalize() {
    #expect(Validator.normalizeShortcut("shift+cmd+t") == Validator.normalizeShortcut("cmd+shift+T"))
    #expect(Validator.normalizeShortcut("alt+cmd+n") == "opt+cmd+n")
    #expect(Validator.isValidShortcut("cmd+shift+["))
    #expect(!Validator.isValidShortcut("hyper+t"))
}

@Test func pascalCaseIds() {
    #expect(pascalCase("command-bar") == "CommandBar")
    #expect(pascalCase("pip") == "Pip")
}
