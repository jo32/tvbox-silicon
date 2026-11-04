import Foundation
import Testing
@testable import TVCore

// MARK: - 说明
//
// 本文件补 `PrivacyVault` 在口令下限、限流持久化、解锁到期三块的专项覆盖。
// `PrivacyVault` 是 `struct`（非 `@MainActor`、非 `@Observable` class），故测试无需
// `@MainActor`，也与现有 `PrivacyVaultTests.swift` 的自由函数风格一致。
//
// 关键事实（以 Sources/TVCore/PrivacyVault.swift 为准）：
//   * `minimumLength == 6`：`setPasscode` 只校验 `passcode.count >= 6`，不校验字符集。
//   * `failedAttempts` / `cooldownEnds` 都在 `CodingKeys` 中，随 Codable 持久化；
//     `unlockedAt` / `revision` 不在 `CodingKeys` 中，重启即清零。
//   * 冷却触发：`failedAttempts >= attemptsBeforeCooldown(5)` 时，
//     `step = failedAttempts - 5`，`cooldownEnds = now + min(300, 8 * 2^step)`。
//   * 冷却判断是严格小于：`now < cooldownEnds` 才拒绝，`now == cooldownEnds` 允许重试。

/// 固定时钟，避免 `Date()` 的实时差异，保证断言可复现。
private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

/// 建一个已设好口令的 vault，`rounds: 10` 让派生足够快。
private func passcodedVault(_ passcode: String = "123456",
                            unlockDuration: TimeInterval = 300,
                            now: Date = fixedNow) throws -> PrivacyVault {
    var vault = PrivacyVault(rounds: 10, unlockDuration: unlockDuration)
    try vault.setPasscode(passcode, now: now)
    return vault
}

/// 连续失败直到触发冷却，返回「刚好进入冷却」的 vault 及其 `cooldownEnds`。
private func vaultInCooldown(now: Date = fixedNow) throws -> (PrivacyVault, Date) {
    var vault = try passcodedVault(now: now)
    for _ in 0..<PrivacyVault.attemptsBeforeCooldown {
        vault.unlock("000000", now: now)
    }
    let until = try #require(vault.cooldownEnds)
    return (vault, until)
}

// MARK: - 口令下限（6 位）

/// 下限的紧邻下界：5 位被拒（现有测试只测了 4 位，这里补最小值的相邻边界）。
@Test func aFiveDigitPasscodeIsRefused() {
    var vault = PrivacyVault(rounds: 10)
    #expect(throws: PrivacyVault.PasscodeError.tooShort) {
        try vault.setPasscode("12345", now: fixedNow)
    }
    #expect(!vault.hasPasscode)
}

/// 6 位（恰好下限）被接受。
@Test func aSixDigitPasscodeIsAccepted() throws {
    var vault = PrivacyVault(rounds: 10)
    try vault.setPasscode("123456", now: fixedNow)
    #expect(vault.hasPasscode)
    let opened = vault.unlock("123456", now: fixedNow)
    #expect(opened)
}

/// 超过下限（8 位）被接受。
@Test func anEightDigitPasscodeIsAccepted() throws {
    var vault = PrivacyVault(rounds: 10)
    try vault.setPasscode("12345678", now: fixedNow)
    #expect(vault.hasPasscode)
    let opened = vault.unlock("12345678", now: fixedNow)
    #expect(opened)
}

/// 空口令被拒。
@Test func anEmptyPasscodeIsRefused() {
    var vault = PrivacyVault(rounds: 10)
    #expect(throws: PrivacyVault.PasscodeError.tooShort) {
        try vault.setPasscode("", now: fixedNow)
    }
    #expect(!vault.hasPasscode)
}

/// 源码默认只校验长度、不校验字符集：任意 ≥6 个字符（含字母、含空格）都被接受。
/// 这是对默认行为的如实记录——`requireDigits` 默认关闭，字符集校验是可选收紧，不影响存量口令。
@Test func anySixOrMoreCharactersAreAcceptedBecauseOnlyLengthIsCheckedByDefault() throws {
    var letters = PrivacyVault(rounds: 10)
    try letters.setPasscode("abcdef", now: fixedNow)
    let openedLetters = letters.unlock("abcdef", now: fixedNow)
    #expect(openedLetters)

    var mixed = PrivacyVault(rounds: 10)
    try mixed.setPasscode("12 456", now: fixedNow) // 含空格的 6 字符
    let openedMixed = mixed.unlock("12 456", now: fixedNow)
    #expect(openedMixed)
}

// MARK: - 数字口令开关（requireDigits）

/// 开关关闭（默认）：含字母的口令照常被接受，行为与旧版完全一致。
@Test func lettersAreAcceptedWhenRequireDigitsIsOff() throws {
    var vault = PrivacyVault(rounds: 10)
    vault.requireDigits = false
    try vault.setPasscode("abcdef", now: fixedNow)
    #expect(vault.hasPasscode)
    let opened = vault.unlock("abcdef", now: fixedNow)
    #expect(opened)
}

/// 开关打开：含字母的 ≥6 字符口令被拒，且不产生任何口令状态。
@Test func lettersAreRefusedWhenRequireDigitsIsOn() throws {
    var vault = PrivacyVault(rounds: 10)
    vault.requireDigits = true
    #expect(throws: PrivacyVault.PasscodeError.notNumeric) {
        try vault.setPasscode("abcdef", now: fixedNow)
    }
    #expect(!vault.hasPasscode)
}

/// 开关打开：含空格/标点的口令同样被拒。
@Test func punctuationAndSpaceAreRefusedWhenRequireDigitsIsOn() throws {
    var vault = PrivacyVault(rounds: 10)
    vault.requireDigits = true
    #expect(throws: PrivacyVault.PasscodeError.notNumeric) {
        try vault.setPasscode("12 456", now: fixedNow)
    }
    // 仍不能设出口令。
    #expect(!vault.hasPasscode)
}

/// 开关打开：纯数字口令（含 6 位下限）被接受，正常解锁。
@Test func digitsAreAcceptedWhenRequireDigitsIsOn() throws {
    var vault = PrivacyVault(rounds: 10)
    vault.requireDigits = true
    try vault.setPasscode("123456", now: fixedNow)
    #expect(vault.hasPasscode)
    let opened = vault.unlock("123456", now: fixedNow)
    #expect(opened)
}

/// 开关打开：替换口令时同样校验字符集——用错误字符集替换应被拒且旧口令不变。
@Test func replacingStillChecksDigitsWhenRequireDigitsIsOn() throws {
    var vault = PrivacyVault(rounds: 10)
    vault.requireDigits = true
    try vault.setPasscode("123456", now: fixedNow)

    #expect(throws: PrivacyVault.PasscodeError.notNumeric) {
        try vault.setPasscode("abcdef", replacing: "123456", now: fixedNow)
    }
    // 旧口令仍有效。
    let oldWorks = vault.unlock("123456", now: fixedNow)
    #expect(oldWorks)
}

// MARK: - 替换口令需验证当前口令

/// 已设口令后，`setPasscode(_:replacing:)` 必须提供正确的 `current`。
@Test func replacingThePasscodeRequiresTheCurrentOne() throws {
    var vault = try passcodedVault(now: fixedNow)

    #expect(throws: PrivacyVault.PasscodeError.wrongPasscode) {
        try vault.setPasscode("654321", replacing: "000000", now: fixedNow)
    }
    // 失败的替换不应改动口令。
    let stillOld = vault.unlock("123456", now: fixedNow)
    #expect(stillOld)

    try vault.setPasscode("654321", replacing: "123456", now: fixedNow)
    let newWorks = vault.unlock("654321", now: fixedNow)
    #expect(newWorks)
    let oldRejected = vault.unlock("123456", now: fixedNow)
    #expect(!oldRejected)
}

// MARK: - 限流（P2-12）

/// 前 `attemptsBeforeCooldown - 1` 次失败只递增 `failedAttempts`、不触发冷却；
/// 第 `attemptsBeforeCooldown` 次触发 `cooldownEnds = now + 8s`。
@Test func theFifthFailureTriggersACooldown() throws {
    var vault = try passcodedVault(now: fixedNow)

    for _ in 0..<(PrivacyVault.attemptsBeforeCooldown - 1) {
        vault.unlock("000000", now: fixedNow)
    }
    #expect(vault.failedAttempts == PrivacyVault.attemptsBeforeCooldown - 1)
    #expect(vault.cooldownEnds == nil)

    vault.unlock("000000", now: fixedNow)
    #expect(vault.failedAttempts == PrivacyVault.attemptsBeforeCooldown)
    #expect(vault.cooldownEnds?.timeIntervalSince(fixedNow) == 8)
}

/// 冷却期内即使口令正确也被拒，且拒绝不继续累加失败；冷却结束后可重试并清零。
@Test func unlockIsRefusedDuringCooldownAndRetriedAfter() throws {
    let (state, until) = try vaultInCooldown(now: fixedNow)
    var vault = state

    // 冷却期内（含正确口令）被拒，且不递增 failedAttempts。
    let midCooldown = fixedNow.addingTimeInterval(4)
    let refusedMid = vault.unlock("123456", now: midCooldown)
    #expect(!refusedMid)
    #expect(vault.failedAttempts == PrivacyVault.attemptsBeforeCooldown)

    // 冷却结束后可重试，成功清零失败计数。
    let retried = vault.unlock("123456", now: until.addingTimeInterval(0.001))
    #expect(retried)
    #expect(vault.failedAttempts == 0)
    let stillUnlocked = vault.isUnlocked(now: until.addingTimeInterval(0.001))
    #expect(stillUnlocked)
}

/// 冷却判断是严格小于：`now == cooldownEnds` 的临界点允许重试。
@Test func cooldownAtExactlyItsEndPermitsRetry() throws {
    let (state, until) = try vaultInCooldown(now: fixedNow)
    var vault = state
    let opened = vault.unlock("123456", now: until)
    #expect(opened)
}

/// 一次成功的解锁把 `failedAttempts` 清零（否则冷却会永久残留）。
@Test func aSuccessfulUnlockClearsFailedAttempts() throws {
    var vault = try passcodedVault(now: fixedNow)
    for _ in 0..<(PrivacyVault.attemptsBeforeCooldown - 1) {
        vault.unlock("000000", now: fixedNow)
    }
    #expect(vault.failedAttempts == PrivacyVault.attemptsBeforeCooldown - 1)

    let opened = vault.unlock("123456", now: fixedNow)
    #expect(opened)
    #expect(vault.failedAttempts == 0)
}

// MARK: - 限流持久化（P2-12：重启不清零）

/// `failedAttempts` / `cooldownEnds` 随 Codable 编码解码往返后保留；
/// `unlockedAt` 不保留，故解码后必处于锁定状态。
@Test func rateLimitSurvivesRelaunch() throws {
    let (state, until) = try vaultInCooldown(now: fixedNow)
    #expect(state.failedAttempts == PrivacyVault.attemptsBeforeCooldown)

    let data = try JSONEncoder().encode(state)
    var reopened = try JSONDecoder().decode(PrivacyVault.self, from: data)

    #expect(reopened.failedAttempts == PrivacyVault.attemptsBeforeCooldown)
    let reopenedUntil = try #require(reopened.cooldownEnds)
    #expect(abs(reopenedUntil.timeIntervalSince(until)) < 0.001)

    // 重启后仍锁定（unlockedAt 不恢复）。
    let lockedAfterRelaunch = reopened.isUnlocked(now: fixedNow)
    #expect(!lockedAfterRelaunch)
    // 冷却期内的正确口令仍被拒——限流无法靠杀进程清零。
    let refusedAfterRelaunch = reopened.unlock("123456", now: fixedNow.addingTimeInterval(1))
    #expect(!refusedAfterRelaunch)
}

/// 未进入冷却时，`failedAttempts` 的中间值同样要跨重启保留。
@Test func partialFailedAttemptsAlsoSurviveRelaunch() throws {
    var vault = try passcodedVault(now: fixedNow)
    for _ in 0..<3 {
        vault.unlock("000000", now: fixedNow)
    }
    #expect(vault.failedAttempts == 3)

    let data = try JSONEncoder().encode(vault)
    let reopened = try JSONDecoder().decode(PrivacyVault.self, from: data)
    #expect(reopened.failedAttempts == 3)
    #expect(reopened.cooldownEnds == nil)
}

// MARK: - 解锁到期（P2-13）

/// `unlock()` 成功路径同样设置 `unlockExpiresAt`（`setPasscode` 路径已有现有测试覆盖）。
@Test func unlockingSetsTheExpiryDeadline() throws {
    var vault = try passcodedVault(unlockDuration: 120, now: fixedNow)
    vault.lock()
    #expect(vault.unlockExpiresAt == nil)

    let opened = vault.unlock("123456", now: fixedNow)
    #expect(opened)
    #expect(vault.unlockExpiresAt?.timeIntervalSince(fixedNow) == 120)
}

/// 到期时 `isUnlocked` 清除过期的解锁并返回 false，`unlockExpiresAt` 随之归 nil。
@Test func theDeadlineExpiresAndClearsTheUnlock() throws {
    var vault = try passcodedVault(unlockDuration: 60, now: fixedNow)

    let beforeDeadline = vault.isUnlocked(now: fixedNow.addingTimeInterval(59))
    #expect(beforeDeadline)
    let atDeadline = vault.isUnlocked(now: fixedNow.addingTimeInterval(60))
    #expect(!atDeadline)
    #expect(vault.unlockExpiresAt == nil)
}

/// 远超期限（负剩余时间）同样是锁定态，且已清除解锁。
@Test func aStaleUnlockFarPastTheDeadlineIsLocked() throws {
    var vault = try passcodedVault(unlockDuration: 60, now: fixedNow)
    let locked = vault.isUnlocked(now: fixedNow.addingTimeInterval(10_000))
    #expect(!locked)
    #expect(vault.unlockExpiresAt == nil)
}

/// 手动 `lock()` 清空 `unlockExpiresAt`，但不重置限流计数（限流要跨锁存续）。
@Test func lockingClearsTheDeadlineButKeepsTheRateLimit() throws {
    var vault = try passcodedVault(now: fixedNow)
    #expect(vault.unlockExpiresAt != nil)

    vault.lock()
    #expect(vault.unlockExpiresAt == nil)

    var limited = try passcodedVault(now: fixedNow)
    for _ in 0..<3 {
        limited.unlock("000000", now: fixedNow)
    }
    limited.lock()
    #expect(limited.failedAttempts == 3)
}
