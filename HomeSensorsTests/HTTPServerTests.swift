import Foundation
import Testing
@testable import HomeSensors

/// Starts servers on free ports and talks to them over real TCP connections.
@Suite("HTTP server", .timeLimit(.minutes(1)))
@MainActor
struct HTTPServerTests
{
  @Test("Answers a request and gives the method, path, and host to the handler")
  func answersRequests() async throws
  {
    let server = HTTPServer(port: 0)
    {
      request in
      .text("200 OK", "\(request.method) \(request.path) \(request.host ?? "none")")
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let result = try await exchange(port: port, request: "GET /api/devices?refresh=1 HTTP/1.1\r\nHost: Studio-Mac.local:8080\r\n\r\n")
    #expect(result.reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(result.reply.hasSuffix("GET /api/devices studio-mac.local\n"))
  }

  @Test("Answers a request line without a path with 400")
  func rejectsMalformedRequests() async throws
  {
    let server = HTTPServer(port: 0)
    {
      _ in
      .text("200 OK", "OK")
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let result = try await exchange(port: port, request: "NONSENSE\r\n\r\n")
    #expect(result.reply.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
  }

  @Test("Answers HEAD with the headers only, and sends Allow with a 405")
  func answersHeadWithoutBody() async throws
  {
    let server = HTTPServer(port: 0)
    {
      request in
      request.method == "HEAD" ? .text("200 OK", "OK") : .methodNotAllowed(allow: "GET, HEAD")
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let head = try await exchange(port: port, request: "HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    #expect(head.reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(head.reply.contains("Content-Length: 3\r\n"))
    #expect(head.reply.hasSuffix("\r\n\r\n"))
    let delete = try await exchange(port: port, request: "DELETE / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    #expect(delete.reply.contains("Allow: GET, HEAD\r\n"))
  }

  @Test("Closes a connection that sends nothing when the time limit ends")
  func closesIdleConnections() async throws
  {
    let server = HTTPServer(port: 0, connectionTimeout: .milliseconds(300))
    {
      _ in
      .text("200 OK", "OK")
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let result = try await exchange(port: port, request: "")
    #expect(result.reply.isEmpty)
    #expect(result.seconds >= 0.25)
    #expect(result.seconds < 5)
  }

  @Test("Closes a connection that never finishes its request when the time limit ends")
  func closesUnfinishedRequests() async throws
  {
    let server = HTTPServer(port: 0, connectionTimeout: .milliseconds(300))
    {
      _ in
      .text("200 OK", "OK")
    }
    defer
    {
      server.stop()
    }
    let port = try await startListening(server)
    let result = try await exchange(port: port, request: "GET / HTTP/1.1\r\nHost: localhost\r\n")
    #expect(result.reply.isEmpty)
    #expect(result.seconds >= 0.25)
    #expect(result.seconds < 5)
  }
}
