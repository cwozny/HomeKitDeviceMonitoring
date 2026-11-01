import SwiftUI

@main
struct HomeSensorsApp: App
{
  @State private var store: HomeStore
  @State private var web: WebDashboard

  init()
  {
    let store = HomeStore.forLaunch()
    _store = State(initialValue: store)
    _web = State(initialValue: WebDashboard(store: store))
  }

  var body: some Scene
  {
    WindowGroup
    {
      DashboardView()
        .environment(store)
        .environment(web)
        .task
        {
          web.start()
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 760, minHeight: 480)
        #endif
    }
    .windowResizability(.contentMinSize)
  }
}
