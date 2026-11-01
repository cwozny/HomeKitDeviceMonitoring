import Testing
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
