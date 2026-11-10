import Foundation
import Testing
@testable import HomeSensors

/// A stand-in for a characteristic. It records each call, and it can fail to turn its notification on or off.
final class FakeSwitch: NotificationSwitch
{
  let logName: String
  private(set) var isNotificationEnabled: Bool
  /// The value of each call, in order: true turns the notification on, false turns it off.
  private(set) var calls: [Bool] = []
  private let failingCalls: Set<Bool>

  init(_ logName: String, enabled: Bool, failingCalls: Set<Bool> = [])
  {
    self.logName = logName
    isNotificationEnabled = enabled
    self.failingCalls = failingCalls
  }

  func enableNotification(_ enable: Bool) async throws
  {
    calls.append(enable)
    if failingCalls.contains(enable)
    {
      throw TestFailure(description: "\(logName) failed")
    }

    isNotificationEnabled = enable
  }
}

@Suite("Signing up again for changes")
@MainActor
struct SignUpAgainTests
{
  @Test("Turns a notification that is on off and then on, because turning it on alone doesn't reach the home hub")
  func turnsOffThenOn() async
  {
    let item = FakeSwitch("Sensor 1 Temperature", enabled: true)
    let failures = await HomeStore.signUpAgain([item])
    #expect(item.calls == [false, true])
    #expect(item.isNotificationEnabled)
    #expect(failures.isEmpty)
  }

  @Test("Only turns on a notification that is off")
  func turnsOnWhenOff() async
  {
    let item = FakeSwitch("Sensor 1 Humidity", enabled: false)
    let failures = await HomeStore.signUpAgain([item])
    #expect(item.calls == [true])
    #expect(item.isNotificationEnabled)
    #expect(failures.isEmpty)
  }

  @Test("Reports a notification that didn't turn on again, and goes on with the next one")
  func reportsFailedTurnOn() async
  {
    let failing = FakeSwitch("Sensor 2 Leak", enabled: true, failingCalls: [true])
    let next = FakeSwitch("Sensor 2 Battery Level", enabled: true)
    let failures = await HomeStore.signUpAgain([failing, next])
    var names: [String] = []
    for failure in failures
    {
      names.append(failure.name)
    }

    #expect(names == ["Sensor 2 Leak"])
    #expect(!failing.isNotificationEnabled)
    #expect(next.calls == [false, true])
    #expect(next.isNotificationEnabled)
  }

  @Test("Leaves a notification on when it couldn't turn off, and reports it")
  func reportsFailedTurnOff() async
  {
    let item = FakeSwitch("Sensor 3 Contact", enabled: true, failingCalls: [false])
    let failures = await HomeStore.signUpAgain([item])
    #expect(item.calls == [false])
    #expect(item.isNotificationEnabled)
    #expect(failures.count == 1)
  }
}

@Suite("Pauses between pushes")
@MainActor
struct PushPauseTests
{
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("The first push has no pause before it")
  func firstPush()
  {
    #expect(HomeStore.longPauseMinutes(from: nil, to: Self.now) == nil)
  }

  @Test("A pause of up to 10 minutes isn't long", arguments: [0, 60, 599, 600] as [TimeInterval])
  func shortPause(seconds: TimeInterval)
  {
    #expect(HomeStore.longPauseMinutes(from: Self.now.addingTimeInterval(-seconds), to: Self.now) == nil)
  }

  @Test("A pause of more than 10 minutes is long, in whole minutes", arguments: [
    (601, 10),
    (659, 10),
    (660, 11),
    (2220, 37),
  ] as [(TimeInterval, Int)])
  func longPause(seconds: TimeInterval, minutes: Int)
  {
    #expect(HomeStore.longPauseMinutes(from: Self.now.addingTimeInterval(-seconds), to: Self.now) == minutes)
  }
}
