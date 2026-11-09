import Foundation
import Testing
@testable import HomeSensors

@Suite("Host-name check")
struct HostCheckTests
{
  @Test("Allows addresses, localhost, and Bonjour names", arguments: [
    "localhost",
    "127.0.0.1",
    "192.168.1.20",
    "100.64.0.7",
    "::1",
    "fe80::1",
    "studio-mac.local",
  ])
  func allowsLocalNames(host: String)
  {
    #expect(WebRouter.allows(host: host))
  }

  @Test("Refuses public names and names without a dot, which DNS rebinding needs", arguments: [
    // A short name, which a DNS search domain can complete.
    "studio-mac",
    "example.com",
    "attacker.example",
    // A VPN name is refused unless the build settings list it.
    "studio-mac.example-vpn.net",
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

  @Test("Has no refresh request; the page only reads")
  func noRefreshRequest()
  {
    let router = makeRouter()
    #expect(router.response(for: HTTPServer.Request(method: "POST", path: "/api/refresh", host: "localhost")).status == "404 Not Found")
  }

  @Test("Accepts the host name in the address the app shows, even when the allowlist doesn't")
  func acceptsAdvertisedHost()
  {
    let router = makeRouter(advertisedHost: "studio-mac.lan")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "studio-mac.lan")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "other-mac.lan")).status == "403 Forbidden")
  }

  @Test("Accepts the extra host names from the build settings, and no others")
  func acceptsExtraHosts()
  {
    let router = makeRouter(extraHosts: ["studio-mac.example-vpn.net"])
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "studio-mac.example-vpn.net")).status == "200 OK")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "other-mac.example-vpn.net")).status == "403 Forbidden")
    #expect(router.response(for: HTTPServer.Request(method: "GET", path: "/", host: "studio-mac.example-vpn.net.attacker.example")).status == "403 Forbidden")
  }

  @Test("Reads the extra host names from the build setting without case, spaces, or a trailing dot")
  func readsExtraHostNames()
  {
    let names = WebRouter.hostNames(from: "  Studio-Mac.Example-VPN.net   other-mac.example-vpn.net. ")
    #expect(names == ["studio-mac.example-vpn.net", "other-mac.example-vpn.net"])
    #expect(WebRouter.hostNames(from: "").isEmpty)
    #expect(WebRouter.hostNames(from: nil).isEmpty)
  }

  @Test("Names the allowed method when it refuses one")
  func allowedMethod()
  {
    let router = makeRouter()
    let delete = router.response(for: HTTPServer.Request(method: "DELETE", path: "/api/devices", host: "localhost"))
    #expect(delete.status == "405 Method Not Allowed")
    #expect(delete.allow == "GET")
  }

  private func makeRouter(advertisedHost: String? = nil, extraHosts: Set<String> = []) -> WebRouter
  {
    WebRouter(
      content: WebContent(page: Data("<!doctype html>".utf8)),
      history: ReadingHistory(fileURL: nil),
      advertisedHost: advertisedHost,
      extraHosts: extraHosts
    )
  }
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
