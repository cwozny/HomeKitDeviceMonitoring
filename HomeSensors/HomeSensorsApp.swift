import SwiftUI

@main
struct HomeSensorsApp: App
{
  /// Xcode runs the unit tests inside the app. Then the app starts neither HomeKit nor the web server.
  static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  @State private var store: HomeStore
  @State private var web: WebDashboard

  init()
  {
    let store = HomeStore.forLaunch()
    let web = WebDashboard(store: store)
    _store = State(initialValue: store)
    _web = State(initialValue: web)
    // Started here, not from a view, so they also run when the app gets no window.
    if !Self.isRunningTests
    {
      store.start()
      web.start()
    }
  }

  var body: some Scene
  {
    WindowGroup
    {
      if Self.isRunningTests
      {
        Text("Running tests")
      }
      else
      {
        DashboardView()
          .environment(store)
          .environment(web)
          #if targetEnvironment(macCatalyst)
          .frame(minWidth: 760, minHeight: 480)
          #endif
      }
    }
    .windowResizability(.contentMinSize)
  }
}
