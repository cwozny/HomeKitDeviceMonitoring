import Foundation

/// The JSON the web page renders. Text is formatted here so the page matches the app.
struct WebPayload: Encodable
{
  struct Tile: Encodable
  {
    var label: String
    var value: String
    var detail: String
    var status: String?
  }

  struct BatteryInfo: Encodable
  {
    var level: Int?
    var text: String
    var severity: String
    var charging: Bool
    var description: String
  }

  struct ReadingInfo: Encodable
  {
    var name: String
    var text: String
    /// The `kind` of the history series for this reading. Nil for kinds the History view doesn't chart.
    var kind: String?
    var alert: String?
    var active: Bool
    var quiet: Bool
  }

  struct DeviceInfo: Encodable
  {
    var id: String
    var name: String
    var section: String
    var room: String
    var model: String?
    var reachable: Bool
    var batterySortKey: Int
    var battery: BatteryInfo?
    var readings: [ReadingInfo]
  }

  var phase: String
  var lastRefresh: Date?
  var isRefreshing: Bool
  var tiles: [Tile]
  var devices: [DeviceInfo]
  var build = BuildInfo.current

  @MainActor
  init(store: HomeStore)
  {
    phase = String(describing: store.phase)
    lastRefresh = store.lastRefresh
    isRefreshing = store.isRefreshing
    var tiles: [Tile] = []
    for tile in Summary(devices: store.devices).tiles
    {
      tiles.append(Tile(label: tile.label, value: tile.value, detail: tile.detail, status: tile.status.map(String.init(describing:))))
    }
    self.tiles = tiles
    let showHome = store.homeCount > 1
    var devices: [DeviceInfo] = []
    for device in store.devices
    {
      devices.append(DeviceInfo(device: device, showHome: showHome))
    }
    self.devices = devices
  }

  func encoded() -> Data
  {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }
}

extension WebPayload.DeviceInfo
{
  init(device: DeviceSnapshot, showHome: Bool)
  {
    var battery: WebPayload.BatteryInfo?
    if let power = device.battery
    {
      battery = WebPayload.BatteryInfo(
        level: power.level,
        text: power.text,
        severity: String(describing: power.severity),
        charging: power.charging == .charging,
        description: power.accessibilityDescription
      )
    }
    var readings: [WebPayload.ReadingInfo] = []
    for reading in device.readings where reading.isVisible
    {
      // The app shows humidity next to an icon; the page has no icons, so it says "RH".
      let text = reading.kind == .humidity ? "\(reading.text) RH" : reading.text
      readings.append(WebPayload.ReadingInfo(
        name: reading.name,
        text: text,
        kind: reading.kind.historyKey,
        alert: reading.alert.map(String.init(describing:)),
        active: reading.isActive,
        quiet: reading.isQuiet
      ))
    }
    self.init(
      id: device.id.uuidString,
      name: device.name,
      section: showHome ? "\(device.home) · \(device.room)" : device.room,
      room: device.room,
      model: device.model,
      reachable: device.isReachable,
      batterySortKey: device.batterySortKey == Int.max ? 1000 : device.batterySortKey,
      battery: battery,
      readings: readings
    )
  }
}
