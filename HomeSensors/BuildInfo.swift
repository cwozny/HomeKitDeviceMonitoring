import Foundation

/// Which build of the app is running. The "Record Git Commit" build phase writes BuildInfo.plist into the app.
struct BuildInfo: Encodable, Equatable
{
  /// The full commit SHA, or "unknown" when the app wasn't built from a Git checkout.
  var commit: String
  /// True when the build included changes that weren't committed.
  var modified: Bool

  static let current = BuildInfo(bundle: .main)

  init(bundle: Bundle)
  {
    var record: [String: Any]?
    if let url = bundle.url(forResource: "BuildInfo", withExtension: "plist")
    {
      record = NSDictionary(contentsOf: url) as? [String: Any]
    }
    self.init(record: record)
  }

  init(record: [String: Any]?)
  {
    commit = record?["Commit"] as? String ?? "unknown"
    modified = record?["Modified"] as? Bool ?? false
  }
}
