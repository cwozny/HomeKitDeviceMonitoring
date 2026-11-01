import Foundation
import Testing
@testable import HomeSensors

@Suite("Host-name check")
struct HostCheckTests
{
  @Test("Allows addresses, localhost, Bonjour names, and Tailscale names", arguments: [
    "localhost",
    "127.0.0.1",
    "192.168.1.20",
    "100.64.0.7",
    "::1",
    "fe80::1",
    "studio-mac.local",
    "studio-mac.example-tailnet.ts.net",
    "studio-mac",
  ])
  func allowsLocalNames(host: String)
  {
    #expect(WebRouter.allows(host: host))
  }

  @Test("Refuses public names, which DNS rebinding needs", arguments: [
    "example.com",
    "attacker.example",
    "studio-mac.ts.net.attacker.example",
    "local.example.com",
    "localhost.example.com",
    "192.168.1.20.example.com",
  ])
  func refusesPublicNames(host: String)
  {
    #expect(!WebRouter.allows(host: host))
  }

  @Test("Refuses a request without an allowed host before it routes the request")
  func refusesBeforeRouting()
  {
    let router = makeRouter()
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/api/devices", host: nil)).status == "403 Forbidden")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/api/devices", host: "example.com")).status == "403 Forbidden")
  }

  @Test("Routes requests from allowed hosts")
  func routesAllowedRequests()
  {
    let router = makeRouter()
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "localhost")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/api/devices", host: "studio-mac.local")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/api/history", host: "192.168.1.20")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "DELETE", path: "/api/devices", host: "localhost")).status == "405 Method Not Allowed")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/missing", host: "localhost")).status == "404 Not Found")
  }

  @Test("Asks for a refresh only for POST /api/refresh from an allowed host")
  func requestsRefresh()
  {
    let counter = Counter()
    let router = makeRouter
    {
      counter.count += 1
    }
    _ = router.response(for: HTTPServer.Request(method: "GET", path: "/api/refresh", host: "localhost"))
    _ = router.response(for: HTTPServer.Request(method: "POST", path: "/api/refresh", host: "example.com"))
    #expect(counter.count == 0)
    #expect(router.response(for: HTTPServer.Request(method: "POST", path: "/api/refresh", host: "localhost")).status == "202 Accepted")
    #expect(counter.count == 1)
  }

  @Test("Refuses a refresh that a page on another site asks for")
  func refusesCrossSiteRefresh()
  {
    let counter = Counter()
    let router = makeRouter
    {
      counter.count += 1
    }
    let crossSite = HTTPServer.Request(method: "POST", path: "/api/refresh", host: "192.168.1.20", fetchSite: "cross-site")
    #expect(router.response(for: crossSite).status == "403 Forbidden")
    #expect(counter.count == 0)
    let sameOrigin = HTTPServer.Request(method: "POST", path: "/api/refresh", host: "192.168.1.20", fetchSite: "same-origin")
    #expect(router.response(for: sameOrigin).status == "202 Accepted")
    #expect(counter.count == 1)
  }

  @Test("Accepts the host name in the address the app shows, even when the allowlist doesn't")
  func acceptsAdvertisedHost()
  {
    let router = makeRouter(advertisedHost: "studio-mac.lan")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "studio-mac.lan")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "other-mac.lan")).status == "403 Forbidden")
  }

  @Test("Answers HEAD like GET and names the allowed methods when it refuses one")
  func headAndAllowedMethods()
  {
    let router = makeRouter()
    #expect(router.response(for: HTTPServer.Request(method: "HEAD", path: "/", host: "localhost")).status == "200 OK")
    let delete = router.response(for: HTTPServer.Request(method: "DELETE", path: "/api/devices", host: "localhost"))
    #expect(delete.status == "405 Method Not Allowed")
    #expect(delete.allow == "GET, HEAD")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/api/refresh", host: "localhost")).allow == "POST")
  }

  private func makeRouter(advertisedHost: String? = nil, requestRefresh: @escaping () -> Void = ignoreRefresh) -> WebRouter
  {
    WebRouter(
      content: WebContent(page: Data("<!doctype html>".utf8)),
      history: ReadingHistory(fileURL: nil),
      advertisedHost: advertisedHost,
      requestRefresh: requestRefresh
    )
  }
}

/// Stands in for a refresh in tests that don't count refreshes.
private func ignoreRefresh()
{
}

private final class Counter
{
  var count = 0
}

@Suite("Host header")
struct HostHeaderTests
{
  @Test("Reads the host name without its port, brackets, case, or trailing dot", arguments: [
    ("Host: Studio-Mac.LOCAL:8080", "studio-mac.local"),
    ("host:   studio-mac.example-tailnet.ts.net  ", "studio-mac.example-tailnet.ts.net"),
    ("HOST: [fe80::1]:8080", "fe80::1"),
    ("Host: [::1]", "::1"),
    ("Host: studio-mac.", "studio-mac"),
    ("Host: 192.168.1.20:8080", "192.168.1.20"),
  ])
  func readsHostName(line: String, expected: String)
  {
    #expect(HTTPServer.host(in: ["Accept: */*", line, "User-Agent: Tests"]) == expected)
  }

  @Test("Gives no host when the header is missing, empty, repeated, or damaged")
  func noHostForBadHeaders()
  {
    #expect(HTTPServer.host(in: ["Accept: */*"]) == nil)
    #expect(HTTPServer.host(in: ["Host:"]) == nil)
    #expect(HTTPServer.host(in: ["Host: studio-mac.local", "Host: example.com"]) == nil)
    #expect(HTTPServer.host(in: ["Host: [fe80::1"]) == nil)
  }
}
