import Foundation
import Testing
@testable import HomeSensors

@Suite("Build info")
struct BuildInfoTests
{
  /// The repository this test file is in. The commit check runs only in a Git checkout.
  private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  private static let isGitCheckout = FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path)

  @Test("Reads the version, commit, and modified flag from the build record")
  func readsRecord()
  {
    let commit = "0123456789abcdef0123456789abcdef01234567"
    let info = BuildInfo(version: "1.0", record: ["Commit": commit, "Modified": true])
    #expect(info.version == "1.0")
    #expect(info.commit == commit)
    #expect(info.modified)
  }

  @Test("Says unknown when the app has no build record")
  func noRecord()
  {
    let info = BuildInfo(version: nil, record: nil)
    #expect(info.version == "unknown")
    #expect(info.commit == "unknown")
    #expect(!info.modified)
  }

  @Test("The build recorded the full commit SHA", .enabled(if: isGitCheckout))
  func recordsCommit()
  {
    let commit = BuildInfo.current.commit
    let isHexadecimal = commit.allSatisfy(\.isHexDigit)
    #expect(commit.count == 40)
    #expect(isHexadecimal)
  }

  #if DEBUG
  @Test("The page data includes the build info")
  @MainActor
  func pageDataIncludesBuild() throws
  {
    let data = WebPayload(store: HomeStore.demo()).encoded()
    let page = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let build = try #require(page["build"] as? [String: Any])
    #expect(build["commit"] as? String == BuildInfo.current.commit)
    #expect(build["version"] as? String == BuildInfo.current.version)
    #expect(build["modified"] as? Bool == BuildInfo.current.modified)
  }
  #endif
}
