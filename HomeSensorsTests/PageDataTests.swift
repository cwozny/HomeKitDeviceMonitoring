import Foundation
import Testing
@testable import HomeSensors

#if DEBUG
@Suite("Page data")
struct PageDataTests
{
  @Test("The page data says when the app last got information from HomeKit")
  @MainActor
  func lastUpdate() throws
  {
    let data = WebPayload(store: HomeStore.demo()).encoded()
    let page = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(page["lastUpdate"] is String)
    #expect(page["lastRefresh"] == nil)
    #expect(page["isRefreshing"] == nil)
  }
}
#endif
