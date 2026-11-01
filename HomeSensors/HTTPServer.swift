import Foundation
import Network

/// A minimal HTTP/1.1 server: one request per connection, request bodies ignored.
final class HTTPServer
{
  struct Request
  {
    var method: String
    var path: String
  }

  struct Response
  {
    var status: String
    var contentType: String
    var body: Data

    static func text(_ status: String, _ message: String) -> Response
    {
      Response(status: status, contentType: "text/plain; charset=utf-8", body: Data((message + "\n").utf8))
    }
  }

  enum State
  {
    case listening(port: UInt16)
    case failed(String)
  }

  private static let maximumHeaderSize = 32 * 1024
  private static let headerTerminator = Data("\r\n\r\n".utf8)

  private let port: UInt16
  private let handler: (Request) -> Response
  private let queue = DispatchQueue(label: "HomeSensors.HTTPServer")
  private var listener: NWListener?

  /// `handler` runs on the server's own queue, never on the main queue.
  init(port: UInt16, handler: @escaping (Request) -> Response)
  {
    self.port = port
    self.handler = handler
  }

  /// Listens on every network interface. `onStateChange` runs on the main actor.
  func start(onStateChange: @escaping @MainActor (State) -> Void)
  {
    guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else
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
        Task
        {
          @MainActor in
          onStateChange(.listening(port: port))
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

  private func accept(_ connection: NWConnection)
  {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data)
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
        self.respond(to: buffer.subdata(in: buffer.startIndex..<end.lowerBound), on: connection)
      }
      else if isComplete || error != nil || buffer.count > Self.maximumHeaderSize
      {
        connection.cancel()
      }
      else
      {
        self.receive(on: connection, buffer: buffer)
      }
    }
  }

  private func respond(to header: Data, on connection: NWConnection)
  {
    let requestLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    let parts = requestLine.split(separator: " ")
    var response = Response.text("400 Bad Request", "Bad request")
    if parts.count >= 2
    {
      var path = String(parts[1])
      if let query = path.firstIndex(of: "?")
      {
        path = String(path[..<query])
      }
      response = handler(Request(method: String(parts[0]), path: path))
    }
    let head = "HTTP/1.1 \(response.status)\r\n"
      + "Content-Type: \(response.contentType)\r\n"
      + "Content-Length: \(response.body.count)\r\n"
      + "Cache-Control: no-store\r\n"
      + "X-Content-Type-Options: nosniff\r\n"
      + "Connection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(response.body)
    let finish: (NWError?) -> Void =
    {
      _ in
      connection.cancel()
    }
    connection.send(content: data, completion: .contentProcessed(finish))
  }
}
