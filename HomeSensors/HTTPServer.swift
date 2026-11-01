import Foundation
import Network

/// A minimal HTTP/1.1 server: one request per connection, request bodies ignored.
final class HTTPServer
{
  struct Request
  {
    var method: String
    var path: String
    /// The Host header in lowercase, without its port or IPv6 brackets. Nil unless there is exactly one.
    var host: String?
    /// The browser's Sec-Fetch-Site header in lowercase, for example "same-origin" or "cross-site". Nil when absent.
    var fetchSite: String? = nil
  }

  struct Response
  {
    var status: String
    var contentType: String
    var body: Data
    /// The methods the path accepts, sent as the Allow header of a 405 response.
    var allow: String? = nil

    static func text(_ status: String, _ message: String) -> Response
    {
      Response(status: status, contentType: "text/plain; charset=utf-8", body: Data((message + "\n").utf8))
    }

    static func methodNotAllowed(allow: String) -> Response
    {
      var response = text("405 Method Not Allowed", "Method not allowed")
      response.allow = allow
      return response
    }
  }

  enum State
  {
    case listening(port: UInt16)
    case failed(String)
  }

  private static let maximumHeaderSize = 32 * 1024
  private static let headerTerminator = Data("\r\n\r\n".utf8)
  /// A client gets this long to receive the response. The history is large, and a phone's link can be slow.
  private static let responseTimeout = DispatchTimeInterval.seconds(120)

  private let port: UInt16
  /// A client gets this long to send its request.
  private let connectionTimeout: DispatchTimeInterval
  private let handler: (Request) -> Response
  private let queue = DispatchQueue(label: "HomeSensors.HTTPServer")
  private var listener: NWListener?

  /// `handler` runs on the server's own queue, never on the main queue.
  /// Port 0 picks a free port, which the `.listening` state reports.
  init(port: UInt16, connectionTimeout: DispatchTimeInterval = .seconds(10), handler: @escaping (Request) -> Response)
  {
    self.port = port
    self.connectionTimeout = connectionTimeout
    self.handler = handler
  }

  /// Listens on every network interface. `onStateChange` runs on the main actor.
  func start(onStateChange: @escaping @MainActor (State) -> Void)
  {
    guard listener == nil, let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) else
    {
      return
    }
    let port = self.port
    let listener: NWListener
    do
    {
      let parameters = NWParameters.tcp
      // Lets the app restart right away even while old connections linger in TIME_WAIT.
      parameters.allowLocalEndpointReuse = true
      listener = try NWListener(using: parameters, on: endpointPort)
    }
    catch
    {
      Task
      {
        @MainActor in
        onStateChange(.failed(error.localizedDescription))
      }
      return
    }
    listener.stateUpdateHandler =
    {
      [weak listener] state in
      switch state
      {
      case .ready:
        let actualPort = listener?.port?.rawValue ?? port
        Task
        {
          @MainActor in
          onStateChange(.listening(port: actualPort))
        }
      case .failed(let error):
        listener?.cancel()
        Task
        {
          @MainActor in
          onStateChange(.failed(error.localizedDescription))
        }
      default:
        break
      }
    }
    listener.newConnectionHandler =
    {
      [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  /// Stops listening. Connections already open finish on their own.
  func stop()
  {
    listener?.cancel()
    listener = nil
  }

  private func accept(_ connection: NWConnection)
  {
    connection.start(queue: queue)
    // Closes connections that never finish a request, so they can't pile up and block the server.
    let deadline = DispatchWorkItem
    {
      connection.cancel()
    }
    queue.asyncAfter(deadline: .now() + connectionTimeout, execute: deadline)
    receive(on: connection, buffer: Data(), deadline: deadline)
  }

  private func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem)
  {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192)
    {
      [weak self] data, _, isComplete, error in
      guard let self else
      {
        connection.cancel()
        return
      }
      var buffer = buffer
      if let data
      {
        buffer.append(data)
      }
      if let end = buffer.range(of: Self.headerTerminator)
      {
        // The request is complete. Sending the response has its own, longer time limit.
        deadline.cancel()
        self.respond(to: buffer.subdata(in: buffer.startIndex..<end.lowerBound), on: connection)
      }
      else if isComplete || error != nil || buffer.count > Self.maximumHeaderSize
      {
        connection.cancel()
      }
      else
      {
        self.receive(on: connection, buffer: buffer, deadline: deadline)
      }
    }
  }

  private func respond(to header: Data, on connection: NWConnection)
  {
    let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ")
    var response = Response.text("400 Bad Request", "Bad request")
    var method = ""
    if parts.count >= 2
    {
      method = String(parts[0])
      var path = String(parts[1])
      if let query = path.firstIndex(of: "?")
      {
        path = String(path[..<query])
      }
      let headers = lines.dropFirst()
      response = handler(Request(
        method: method,
        path: path,
        host: Self.host(in: headers),
        fetchSite: Self.values(of: "sec-fetch-site", in: headers).first?.lowercased()
      ))
    }
    var head = "HTTP/1.1 \(response.status)\r\n"
      + "Content-Type: \(response.contentType)\r\n"
      + "Content-Length: \(response.body.count)\r\n"
      + "Cache-Control: no-store\r\n"
      + "X-Content-Type-Options: nosniff\r\n"
    if let allow = response.allow
    {
      head += "Allow: \(allow)\r\n"
    }
    head += "Connection: close\r\n\r\n"
    var data = Data(head.utf8)
    // A HEAD response has the headers that GET would have, without the body.
    if method != "HEAD"
    {
      data.append(response.body)
    }
    // A client that stops reading can't keep the connection open forever either.
    queue.asyncAfter(deadline: .now() + Self.responseTimeout)
    {
      connection.cancel()
    }
    let finish: (NWError?) -> Void =
    {
      _ in
      connection.cancel()
    }
    connection.send(content: data, completion: .contentProcessed(finish))
  }

  /// The values of the header lines with this lowercase name, trimmed of spaces.
  static func values(of name: String, in headerLines: some Sequence<String>) -> [String]
  {
    var values: [String] = []
    for line in headerLines
    {
      guard let colon = line.firstIndex(of: ":") else
      {
        continue
      }
      if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name
      {
        values.append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }
    }
    return values
  }

  /// The value of the request's only Host header, normalized for comparison.
  static func host(in headerLines: some Sequence<String>) -> String?
  {
    let found = values(of: "host", in: headerLines)
    guard found.count == 1 else
    {
      return nil
    }
    var host = found[0].lowercased()
    if host.hasPrefix("[")
    {
      // An IPv6 address, for example "[fe80::1]:8080".
      guard let close = host.firstIndex(of: "]") else
      {
        return nil
      }
      return String(host[host.index(after: host.startIndex)..<close])
    }
    if let colon = host.lastIndex(of: ":")
    {
      host = String(host[..<colon])
    }
    if host.hasSuffix(".")
    {
      host.removeLast()
    }
    return host.isEmpty ? nil : host
  }
}
