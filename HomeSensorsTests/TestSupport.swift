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

/// Starts `server` and returns the port it listens on. A test cancelled at its time limit stops waiting,
/// so it fails instead of hanging the test run.
@MainActor
func startListening(_ server: HTTPServer) async throws -> UInt16
{
  let waiter = PortWaiter()
  return try await withTaskCancellationHandler(
    operation:
    {
      try await withCheckedThrowingContinuation
      {
        continuation in
        waiter.continuation = continuation
        server.start
        {
          state in
          switch state
          {
          case .listening(let port):
            waiter.finish(.success(port))
          case .failed(let message):
            waiter.finish(.failure(TestFailure(description: message)))
          }
        }
      }
    },
    onCancel:
    {
      Task
      {
        @MainActor in
        waiter.finish(.failure(CancellationError()))
      }
    }
  )
}

/// Ends the wait for a port once, from whichever callback comes first.
@MainActor
private final class PortWaiter
{
  var continuation: CheckedContinuation<UInt16, Error>?

  func finish(_ result: Result<UInt16, Error>)
  {
    continuation?.resume(with: result)
    continuation = nil
  }
}

/// Sends `request` over a new TCP connection to this Mac. Returns everything the server sends
/// before it closes the connection, and how long that took. An empty request sends nothing.
/// A refused connection, or a test cancelled at its time limit, ends with an error instead of waiting forever.
func exchange(port: UInt16, request: String) async throws -> (reply: String, seconds: Double)
{
  guard let endpointPort = NWEndpoint.Port(rawValue: port) else
  {
    throw TestFailure(description: "Invalid port \(port)")
  }
  let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
  let queue = DispatchQueue(label: "HomeSensorsTests.client")
  let start = Date.now
  let reply: String = try await withTaskCancellationHandler(
    operation:
    {
      try await withCheckedThrowingContinuation
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
          case .waiting(let error), .failed(let error):
            // A refused connection waits for the network to change instead of failing.
            finish(.failure(error))
          case .cancelled:
            finish(.failure(CancellationError()))
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    },
    onCancel:
    {
      connection.cancel()
    }
  )
  return (reply, Date.now.timeIntervalSince(start))
}

/// A failed send shows up as a failed receive, so the send result itself doesn't matter.
@Sendable
private func ignoreSendResult(_ error: NWError?)
{
}
