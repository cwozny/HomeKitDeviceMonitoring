import Testing
import UIKit
@testable import HomeSensors

@Suite("Test environment")
struct AppTests
{
  @Test("The app knows that tests are running, so it starts neither HomeKit nor the web server")
  func detectsTests()
  {
    #expect(HomeSensorsApp.isRunningTests)
  }
}

@Suite("App window")
struct WindowTests
{
  @Test("The app has one window only, because the window can't be closed or minimized")
  @MainActor
  func oneWindow()
  {
    #expect(!UIApplication.shared.supportsMultipleScenes)
  }
}
