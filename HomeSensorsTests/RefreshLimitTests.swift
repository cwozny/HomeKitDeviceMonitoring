import Foundation
import Testing
@testable import HomeSensors

@Suite("Refresh limit", .timeLimit(.minutes(1)))
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

  @Test("The page gets 429 and Retry-After within a minute of the last refresh, and 202 after it")
  func pageRefreshLimit()
  {
    let counter = RefreshCounter()
    let content = WebContent(page: Data("<!doctype html>".utf8))
    let router = WebRouter(content: content, history: ReadingHistory(fileURL: nil))
    {
      counter.count += 1
    }
    let request = HTTPServer.Request(method: "POST", path: "/api/refresh", host: "localhost", fetchSite: "same-origin")
    content.lastRefresh = Date.now.addingTimeInterval(-10)
    let refused = router.response(for: request)
    let retryAfter = refused.retryAfter ?? 0
    #expect(refused.status == "429 Too Many Requests")
    #expect(retryAfter >= 49 && retryAfter <= 50)
    #expect(counter.count == 0)
    content.lastRefresh = Date.now.addingTimeInterval(-61)
    #expect(router.response(for: request).status == "202 Accepted")
    #expect(counter.count == 1)
  }

  @Test("The server sends the Retry-After header")
  @MainActor
  func sendsRetryAfter() async throws
  {
    let server = HTTPServer(port: 0)
    {
      _ in
      .tooManyRequests(retryAfter: 42)
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let result = try await exchange(port: port, request: "POST /api/refresh HTTP/1.1\r\nHost: localhost\r\n\r\n")
    #expect(result.reply.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
    #expect(result.reply.contains("Retry-After: 42\r\n"))
  }
}

private final class RefreshCounter
{
  var count = 0
}
