import Foundation
import Testing
@testable import HomeSensors

@Suite("Refresh limit")
struct RefreshLimitTests
{
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("Allows a refresh when none has finished yet")
  func noRefreshYet()
  {
    #expect(RefreshLimit.wait(after: nil, now: now) == 0)
  }

  @Test("Waits out the rest of the minute after the last refresh", arguments: [
    (10.0, 50.0),
    (59.0, 1.0),
    (60.0, 0.0),
    (3_600.0, 0.0),
  ])
  func waitsOutTheMinute(secondsAgo: Double, expected: Double)
  {
    #expect(RefreshLimit.wait(after: now.addingTimeInterval(-secondsAgo), now: now) == expected)
  }

  @Test("Allows a refresh after the clock goes back")
  func clockWentBack()
  {
    #expect(RefreshLimit.wait(after: now.addingTimeInterval(3_600), now: now) == 0)
  }
}
