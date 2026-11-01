import Foundation
import Network
@testable import HomeSensors

/// A device snapshot with only the fields a test cares about.
func makeDevice(
  _ name: String,
  id: UUID = UUID(),
  room: String = "Room",
  battery: Battery? = nil,
  readings: [Reading] = [],
  reachable: Bool = true
) -> DeviceSnapshot
{
  DeviceSnapshot(
    id: id,
    name: name,
    home: "Home",
    room: room,
    manufacturer: nil,
    model: nil,
    firmware: nil,
    symbol: "sensor",
    isReachable: reachable,
    battery: battery,
    readings: readings
  )
}

struct TestFailure: Error, CustomStringConvertible
{
  var description: String
}

/// Starts `server` and returns the port it listens on.
@MainActor
func startListening(_ server: HTTPServer) async throws -> UInt16
{
  try await withCheckedThrowingContinuation
  {
    continuation in
    var resumed = false
    server.start
    {
      state in
      if resumed
      {
        return
      }
      resumed = true
      switch state
      {
      case .listening(let port):
        continuation.resume(returning: port)
      case .failed(let message):
        continuation.resume(throwing: TestFailure(description: message))
      }
    }
  }
}

/// Sends `request` over a new TCP connection to this Mac. Returns everything the server sends
/// before it closes the connection, and how long that took. An empty request sends nothing.
func exchange(port: UInt16, request: String) async throws -> (reply: String, seconds: Double)
{
  guard let endpointPort = NWEndpoint.Port(rawValue: port) else
  {
    throw TestFailure(description: "Invalid port \(port)")
  }
  let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
  let queue = DispatchQueue(label: "HomeSensorsTests.client")
  let start = Date.now
  let reply: String = try await withCheckedThrowingContinuation
  {
    continuation in
    var received = Data()
    var finished = false
    func finish(_ result: Result<String, Error>)
    {
      if finished
      {
        return
      }
      finished = true
      connection.cancel()
      continuation.resume(with: result)
    }
    func receive()
    {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536)
      {
        data, _, isComplete, error in
        if let data
        {
          received.append(data)
        }
        if isComplete || error != nil
        {
          // The server closed the connection.
          finish(.success(String(decoding: received, as: UTF8.self)))
        }
        else
        {
          receive()
        }
      }
    }
    connection.stateUpdateHandler =
    {
      state in
      switch state
      {
      case .ready:
        if !request.isEmpty
        {
          connection.send(content: Data(request.utf8), completion: .contentProcessed(ignoreSendResult))
        }
        receive()
      case .failed(let error):
        finish(.failure(error))
      default:
        break
      }
    }
    connection.start(queue: queue)
  }
  return (reply, Date.now.timeIntervalSince(start))
}

/// A failed send shows up as a failed receive, so the send result itself doesn't matter.
@Sendable
private func ignoreSendResult(_ error: NWError?)
{
}
