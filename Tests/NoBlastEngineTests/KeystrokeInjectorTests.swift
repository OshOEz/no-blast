import Testing
@testable import NoBlastEngine

@Test func passwordsBecomeOneUnicodePressPerCharacterThenReturn() {
    let presses = KeystrokeInjector.presses(for: "é a😀")
    #expect(presses.count == 5)
    #expect(presses[0].unicode == Array("é".utf16))
    #expect(presses[1].unicode == Array(" ".utf16))
    #expect(presses[3].unicode == Array("😀".utf16)) // a surrogate pair, still one key press
    #expect(presses.dropLast().allSatisfy { $0.waitAfterRelease })
    #expect(presses.last?.virtualKey == 0x24)
    #expect(presses.last?.unicode == nil)
    #expect(presses.last?.waitAfterRelease == false)
}

@Test func anEmptyPasswordIsJustReturn() {
    #expect(KeystrokeInjector.presses(for: "").map(\.virtualKey) == [0x24])
}
