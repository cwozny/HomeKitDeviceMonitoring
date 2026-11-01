import Foundation
import Observation

/// Serves the dashboard as a web page so phones on the same network can open it.
/// Runs only in the Mac app.
@MainActor
@Observable
final class WebDashboard
{
  static let defaultPort: UInt16 = 8080

  private(set) var address: String?
  private(set) var failure: String?

  private let store: HomeStore
  private let content = WebContent(page: WebDashboard.loadPage())
  @ObservationIgnored private var server: HTTPServer?
  @ObservationIgnored private var history: ReadingHistory?
  @ObservationIgnored private var activity: NSObjectProtocol?

  init(store: HomeStore)
  {
    self.store = store
  }

  func start()
  {
    #if targetEnvironment(macCatalyst)
    guard server == nil else
    {
      return
    }
    let history = ReadingHistory.forLaunch()
    self.history = history
    publish()
    let store = self.store
    let router = WebRouter(content: content, history: history)
    {
      Task
      {
        @MainActor in
        await store.refresh()
      }
    }
    let server = HTTPServer(port: Self.configuredPort, handler: router.response(for:))
    server.start
    {
      [weak self] state in
      self?.update(state)
    }
    self.server = server
    // App Nap would throttle the app while its window is hidden; a server must answer promptly.
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Serving the Home Sensors web dashboard"
    )
    #endif
  }

  private func update(_ state: HTTPServer.State)
  {
    switch state
    {
    case .listening(let port):
      address = "http://\(Self.hostName):\(port)"
      failure = nil
    case .failed(let message):
      address = nil
      failure = "Web dashboard unavailable: \(message)"
    }
  }

  /// Re-encodes the payload and records new readings whenever anything the page shows changes.
  private func publish()
  {
    content.payload = withObservationTracking(
      {
        WebPayload(store: store).encoded()
      },
      onChange:
      {
        [weak self] in
        Task
        {
          @MainActor in
          self?.publish()
        }
      }
    )
    history?.record(store.devices)
  }

  /// Override with `defaults write <bundle identifier> WebServerPort <port>`.
  private static var configuredPort: UInt16
  {
    let value = UserDefaults.standard.integer(forKey: "WebServerPort")
    if value > 0 && value <= Int(UInt16.max)
    {
      return UInt16(value)
    }
    return defaultPort
  }

  private static var hostName: String
  {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else
    {
      return "localhost"
    }
    let name = String(cString: buffer).lowercased()
    return name.contains(".") ? name : name + ".local"
  }

  private static func loadPage() -> Data
  {
    if let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"), let data = try? Data(contentsOf: url)
    {
      return data
    }
    return Data("<!doctype html><title>Home Sensors</title><p>The dashboard page is missing from the app.</p>".utf8)
  }
}

/// The page and the latest JSON, shared with the server's queue.
final class WebContent: @unchecked Sendable
{
  let page: Data
  private let lock = NSLock()
  private var latest = Data("{}".utf8)

  init(page: Data)
  {
    self.page = page
  }

  var payload: Data
  {
    get
    {
      lock.withLock
      {
        latest
      }
    }
    set
    {
      lock.withLock
      {
        latest = newValue
      }
    }
  }
}

/// Maps requests to responses. Runs on the server's queue.
struct WebRouter
{
  let content: WebContent
  let history: ReadingHistory
  let requestRefresh: () -> Void

  func response(for request: HTTPServer.Request) -> HTTPServer.Response
  {
    switch (request.method, request.path)
    {
    case ("GET", "/"), ("GET", "/index.html"):
      return HTTPServer.Response(status: "200 OK", contentType: "text/html; charset=utf-8", body: content.page)
    case ("GET", "/api/devices"):
      return HTTPServer.Response(status: "200 OK", contentType: "application/json; charset=utf-8", body: content.payload)
    case ("GET", "/api/history"):
      return HTTPServer.Response(status: "200 OK", contentType: "application/json; charset=utf-8", body: history.payload())
    case ("POST", "/api/refresh"):
      requestRefresh()
      return .text("202 Accepted", "Refreshing")
    case (_, "/"), (_, "/index.html"), (_, "/api/devices"), (_, "/api/history"), (_, "/api/refresh"):
      return .text("405 Method Not Allowed", "Method not allowed")
    default:
      return .text("404 Not Found", "Not found")
    }
  }
}
