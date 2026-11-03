import SwiftUI

@main
struct HomeSensorsApp: App
{
  /// Xcode runs the unit tests inside the app. Then the app starts neither HomeKit nor the web server.
  static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        StatusView()
          .environment(store)
          .environment(web)
      }
    }
  }
}

/// Removes Hide, Hide Others, and Show All from the app menu. Hiding the app makes it not visible, and
/// HomeKit sends no changes to an app that isn't visible.
final class AppDelegate: UIResponder, UIApplicationDelegate
{
  override func buildMenu(with builder: UIMenuBuilder)
  {
    super.buildMenu(with: builder)
    if builder.system == .main
    {
      builder.remove(menu: .hide)
    }
  }
}
