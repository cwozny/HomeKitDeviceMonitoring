import Foundation

/// Records numeric sensor readings and battery levels so the web page can chart the last 7 days.
/// Samples older than that move to an archive file, which the app only appends to, so none are lost.
/// HomeKit keeps no history, so the record starts when the app first runs.
/// Recording happens on the main actor; the web server reads payloads on its own queue.
final class ReadingHistory: @unchecked Sendable
{
  struct Sample
  {
    var time: TimeInterval
    var value: Double
  }

  /// What one series records: a charted reading, or the battery level.
  enum Quantity: Hashable
  {
    case reading(Reading.Kind)
    case battery

    /// Stable name in the history file and the page data. Nil for readings the History view doesn't chart.
    var historyKey: String?
    {
      switch self
      {
      case .reading(let kind):
        kind.historyKey
      case .battery:
        "battery"
      }
    }

    init?(historyKey: String)
    {
      if historyKey == "battery"
      {
        self = .battery
      }
      else if let kind = Reading.Kind(historyKey: historyKey)
      {
        self = .reading(kind)
      }
      else
      {
        return nil
      }
    }

    /// Each device's charts come in this order: its readings, then its battery level.
    var order: Int
    {
      switch self
      {
      case .reading(let kind):
        kind.rawValue
      case .battery:
        Int.max
      }
    }
  }

  struct Key: Hashable
  {
    var device: UUID
    var quantity: Quantity
  }

  static let window: TimeInterval = 7 * 24 * 60 * 60
  static let bucketSeconds: TimeInterval = 10 * 60
  /// A changed value is recorded at most this often, which keeps chatty sensors in check.
  private static let minimumSpacing: TimeInterval = 60
  /// An unchanged value is recorded this often, so lines continue and gaps mean missing data.
  private static let heartbeat: TimeInterval = 10 * 60
  private static let pruneInterval: TimeInterval = 6 * 60 * 60

  private let fileURL: URL?
  /// Receives the samples older than 7 days. Without it, they're deleted.
  private let archiveURL: URL?
  private let lock = NSLock()
  private var series: [Key: [Sample]] = [:]
  /// When the app recorded its first sample. That sample can be in the archive.
  private var firstRecorded: TimeInterval?
  private var lastPrune: TimeInterval
  private var isFrozen = false

  init(fileURL: URL?, archiveURL: URL? = nil)
  {
    self.fileURL = fileURL
    self.archiveURL = archiveURL
    lastPrune = Date.now.timeIntervalSince1970
    load()
  }

  static func forLaunch() -> ReadingHistory
  {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-demo")
    {
      return demo()
    }
    #endif
    let folder = defaultFolder()
    return ReadingHistory(
      fileURL: folder?.appendingPathComponent("history.tsv"),
      archiveURL: folder?.appendingPathComponent("history-archive.tsv")
    )
  }

  /// ~/Library/Application Support/<bundle ID>, which holds history.tsv and history-archive.tsv.
  private static func defaultFolder() -> URL?
  {
    let manager = FileManager.default
    guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else
    {
      return nil
    }
    let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "HomeSensors", isDirectory: true)
    do
    {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    catch
    {
      return nil
    }
    return folder
  }

  /// Adds the charted readings and battery levels of devices that are responding. Call whenever the devices change.
  func record(_ devices: [DeviceSnapshot], at date: Date = .now)
  {
    if isFrozen
    {
      return
    }
    let now = date.timeIntervalSince1970
    var added: [(Key, Sample)] = []
    lock.withLock
    {
      for device in devices where device.isReachable
      {
        for (quantity, value) in Self.recordedValues(of: device)
        {
          let key = Key(device: device.id, quantity: quantity)
          if let last = series[key]?.last, last.time > now
          {
            // The clock went back. Samples from the future would stop recording until it caught up.
            series[key] = series[key]?.filter
            {
              $0.time <= now
            }
          }
          if let last = series[key]?.last
          {
            let elapsed = now - last.time
            let isDue = elapsed >= Self.heartbeat || (value != last.value && elapsed >= Self.minimumSpacing)
            if !isDue
            {
              continue
            }
          }
          let sample = Sample(time: now, value: value)
          series[key, default: []].append(sample)
          added.append((key, sample))
          firstRecorded = min(firstRecorded ?? now, now)
        }
      }
    }
    append(added, to: fileURL)
    if now - lastPrune >= Self.pruneInterval
    {
      prune(now: now)
    }
  }

  /// The charted readings and the battery level of one device.
  private static func recordedValues(of device: DeviceSnapshot) -> [(Quantity, Double)]
  {
    var values: [(Quantity, Double)] = []
    for reading in device.readings where reading.kind.historyKey != nil
    {
      if let value = reading.value, value.isFinite
      {
        values.append((.reading(reading.kind), value))
      }
    }
    if let level = device.battery?.level
    {
      values.append((.battery, Double(level)))
    }
    return values
  }

  /// The JSON behind the History view: each series for the last 7 days, averaged into 10-minute buckets.
  func payload(at date: Date = .now) -> Data
  {
    let now = date.timeIntervalSince1970
    let start = now - Self.window
    let (snapshot, started) = lock.withLock
    {
      (series, firstRecorded)
    }
    let temperatureUnit = UnitTemperature(forLocale: .current, usage: .weather)
    // By kind in chart order, so the page lists the kinds in its filter in that order. Then by device.
    let keys = snapshot.keys.sorted
    {
      ($0.quantity.order, $0.device.uuidString) < ($1.quantity.order, $1.device.uuidString)
    }
    var list: [HistoryPayload.Series] = []
    for key in keys
    {
      let recent = (snapshot[key] ?? []).filter
      {
        $0.time >= start
      }
      guard !recent.isEmpty, let name = key.quantity.historyKey, let style = ChartStyle(quantity: key.quantity, temperatureUnit: temperatureUnit) else
      {
        continue
      }
      list.append(HistoryPayload.Series(
        device: key.device.uuidString,
        kind: name,
        name: style.name,
        unit: style.unit,
        decimals: style.decimals,
        minimumSpan: style.minimumSpan,
        nonNegative: style.nonNegative,
        maximum: style.maximum,
        showsLowHigh: style.showsLowHigh,
        points: Self.buckets(recent, convert: style.convert)
      ))
    }
    var recordingSince: Int?
    // Not the first sample in the window, because the window can start in a pause.
    if let started
    {
      recordingSince = Int(started)
    }
    let payload = HistoryPayload(
      now: Int(now),
      start: Int(start),
      recordingSince: recordingSince,
      bucketSeconds: Int(Self.bucketSeconds),
      series: list
    )
    return (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
  }

  /// Averages samples into fixed buckets and returns [time, value] pairs in display units.
  /// The buckets follow the clock, not the request time, so the same samples always give the same points.
  private static func buckets(_ samples: [Sample], convert: (Double) -> Double) -> [[Double]]
  {
    var points: [[Double]] = []
    var current = -1
    var timeSum = 0.0
    var valueSum = 0.0
    var count = 0.0
    func flush()
    {
      if count > 0
      {
        let value = convert(valueSum / count)
        points.append([(timeSum / count).rounded(), (value * 10).rounded() / 10])
      }
    }
    for sample in samples
    {
      let bucket = Int((sample.time / bucketSeconds).rounded(.down))
      if bucket != current
      {
        flush()
        current = bucket
        timeSum = 0
        valueSum = 0
        count = 0
      }
      timeSum += sample.time
      valueSum += sample.value
      count += 1
    }
    flush()
    return points
  }

  // MARK: - File

  /// One sample per line: seconds since 1970, device ID, kind, and raw HomeKit value, separated by tabs.
  private static func lines(_ entries: [(Key, Sample)]) -> Data
  {
    var text = ""
    for (key, sample) in entries
    {
      if let kind = key.quantity.historyKey
      {
        text += "\(Int(sample.time))\t\(key.device.uuidString)\t\(kind)\t\(sample.value)\n"
      }
    }
    return Data(text.utf8)
  }

  private func load()
  {
    guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else
    {
      return
    }
    let now = Date.now.timeIntervalSince1970
    let cutoff = now - Self.window
    var loaded: [Key: [Sample]] = [:]
    var old: [(Key, Sample)] = []
    var first = Self.firstTime(in: archiveURL, now: now)
    var dropped = 0
    for line in text.split(separator: "\n")
    {
      let fields = line.split(separator: "\t")
      // Double() also reads "nan", "inf", and overflows such as "1e400", which a damaged file could hold.
      // Those can't be converted to Int or encoded as JSON, and a future time would stop recording.
      guard fields.count == 4,
        let time = Double(fields[0]),
        let device = UUID(uuidString: String(fields[1])),
        let quantity = Quantity(historyKey: String(fields[2])),
        let value = Double(fields[3]),
        value.isFinite,
        time >= 0,
        time <= now
      else
      {
        dropped += 1
        continue
      }
      let key = Key(device: device, quantity: quantity)
      let sample = Sample(time: time, value: value)
      first = min(first ?? time, time)
      if time < cutoff
      {
        old.append((key, sample))
      }
      else
      {
        loaded[key, default: []].append(sample)
      }
    }
    // Archived first, so a crash in between leaves a sample in both files rather than in neither.
    let archived = archive(old)
    if !archived
    {
      // Kept until a later cleanup can archive them.
      for (key, sample) in old
      {
        loaded[key, default: []].append(sample)
      }
    }
    for key in loaded.keys
    {
      loaded[key]?.sort
      {
        $0.time < $1.time
      }
    }
    lock.withLock
    {
      series = loaded
      firstRecorded = first
    }
    if dropped > 0 || (archived && !old.isEmpty)
    {
      rewrite(loaded)
    }
  }

  /// The time on the archive's first line. The archive gets the oldest samples first, so that's when recording started.
  /// Nil when there's no archive or the line has no usable time.
  private static func firstTime(in url: URL?, now: TimeInterval) -> TimeInterval?
  {
    guard let url, let handle = try? FileHandle(forReadingFrom: url) else
    {
      return nil
    }

    defer
    {
      try? handle.close()
    }

    // A line is less than 100 bytes, and the archive grows without limit, so only its start is read.
    guard let data = try? handle.read(upToCount: 1_024),
      let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
      let field = line.split(separator: "\t").first,
      let time = Double(field),
      time >= 0,
      time <= now
    else
    {
      return nil
    }

    return time
  }

  /// Appends samples that left the 7-day window to the archive, oldest first. False if it couldn't write them.
  private func archive(_ entries: [(Key, Sample)]) -> Bool
  {
    let sorted = entries.sorted
    {
      $0.1.time < $1.1.time
    }
    return append(sorted, to: archiveURL)
  }

  /// False if the samples couldn't be written.
  @discardableResult
  private func append(_ entries: [(Key, Sample)], to url: URL?) -> Bool
  {
    guard let url, !entries.isEmpty else
    {
      return true
    }
    let data = Self.lines(entries)
    guard let handle = try? FileHandle(forWritingTo: url) else
    {
      do
      {
        try data.write(to: url)
        return true
      }
      catch
      {
        return false
      }
    }
    defer
    {
      try? handle.close()
    }
    do
    {
      _ = try handle.seekToEnd()
      try handle.write(contentsOf: data)
      return true
    }
    catch
    {
      // Only these samples are lost from this file; recording continues.
      return false
    }
  }

  private func prune(now: TimeInterval)
  {
    lastPrune = now
    let cutoff = now - Self.window
    var kept: [Key: [Sample]] = [:]
    var old: [(Key, Sample)] = []
    lock.withLock
    {
      for (key, samples) in series
      {
        var recent: [Sample] = []
        for sample in samples
        {
          if sample.time < cutoff
          {
            old.append((key, sample))
          }
          else
          {
            recent.append(sample)
          }
        }
        if !recent.isEmpty
        {
          kept[key] = recent
        }
      }
    }
    // Archived first, so a crash in between leaves a sample in both files rather than in neither.
    // If the archive can't be written, nothing is removed, and the next cleanup tries again.
    guard archive(old) else
    {
      return
    }
    // Only recording changes the series, and it runs on this same thread, so nothing changed in between.
    lock.withLock
    {
      series = kept
    }
    rewrite(kept)
  }

  private func rewrite(_ all: [Key: [Sample]])
  {
    guard let fileURL else
    {
      return
    }
    var entries: [(Key, Sample)] = []
    for (key, samples) in all
    {
      for sample in samples
      {
        entries.append((key, sample))
      }
    }
    entries.sort
    {
      $0.1.time < $1.1.time
    }
    try? Self.lines(entries).write(to: fileURL, options: .atomic)
  }
}

/// The JSON behind the web page's History view.
struct HistoryPayload: Encodable
{
  struct Series: Encodable
  {
    var device: String
    var kind: String
    var name: String
    var unit: String
    var decimals: Int
    /// The smallest value range a chart shows, so sensor noise doesn't look like a swing.
    var minimumSpan: Double
    var nonNegative: Bool
    /// The highest value a chart shows. Nil when there's no limit.
    var maximum: Double?
    /// Whether the page shows the low and high, above the chart and in a daily table.
    var showsLowHigh: Bool
    /// [seconds since 1970, value in `unit`] pairs, oldest first.
    var points: [[Double]]
  }

  var now: Int
  var start: Int
  /// When the app recorded its first sample, which can be older than the window. Nil until anything is recorded.
  var recordingSince: Int?
  var bucketSeconds: Int
  var series: [Series]
}

/// How the History view labels and scales one series.
struct ChartStyle
{
  var name: String
  var unit: String
  var decimals: Int
  var minimumSpan: Double
  var nonNegative = true
  var maximum: Double?
  var showsLowHigh = true
  /// Set for temperatures, which HomeKit reports in Celsius.
  var temperatureUnit: UnitTemperature?

  init?(quantity: ReadingHistory.Quantity, temperatureUnit: UnitTemperature)
  {
    switch quantity
    {
    case .reading(let kind):
      self.init(kind: kind, temperatureUnit: temperatureUnit)
    case .battery:
      // A battery only runs down, so its low and high would only repeat the chart.
      self.init(name: "Battery", unit: "%", decimals: 0, minimumSpan: 10, maximum: 100, showsLowHigh: false)
    }
  }

  private init(name: String, unit: String, decimals: Int, minimumSpan: Double, maximum: Double, showsLowHigh: Bool)
  {
    self.name = name
    self.unit = unit
    self.decimals = decimals
    self.minimumSpan = minimumSpan
    self.maximum = maximum
    self.showsLowHigh = showsLowHigh
  }

  init?(kind: Reading.Kind, temperatureUnit: UnitTemperature)
  {
    name = Reading(kind: kind).name
    switch kind
    {
    case .temperature:
      unit = temperatureUnit.symbol
      decimals = 1
      minimumSpan = temperatureUnit == .fahrenheit ? 4 : 2
      nonNegative = false
      self.temperatureUnit = temperatureUnit
    case .humidity:
      unit = "%"
      decimals = 0
      minimumSpan = 10
    case .light:
      unit = "lx"
      decimals = 0
      minimumSpan = 10
    case .carbonDioxide:
      unit = "ppm"
      decimals = 0
      minimumSpan = 200
    case .carbonMonoxide:
      unit = "ppm"
      decimals = 0
      minimumSpan = 5
    case .pm25, .pm10:
      unit = "µg/m³"
      decimals = 0
      minimumSpan = 10
    case .voc:
      unit = "µg/m³"
      decimals = 0
      minimumSpan = 50
    default:
      return nil
    }
  }

  /// Converts a raw HomeKit value into `unit`.
  func convert(_ value: Double) -> Double
  {
    guard let temperatureUnit else
    {
      return value
    }
    return Measurement(value: value, unit: UnitTemperature.celsius).converted(to: temperatureUnit).value
  }
}

extension Reading.Kind
{
  static let charted: [Reading.Kind] = [.temperature, .humidity, .light, .carbonDioxide, .carbonMonoxide, .pm25, .pm10, .voc]

  /// Stable name in the history file. Nil for kinds the History view doesn't chart.
  var historyKey: String?
  {
    switch self
    {
    case .temperature:
      "temperature"
    case .humidity:
      "humidity"
    case .light:
      "light"
    case .carbonDioxide:
      "co2"
    case .carbonMonoxide:
      "co"
    case .pm25:
      "pm25"
    case .pm10:
      "pm10"
    case .voc:
      "voc"
    default:
      nil
    }
  }

  init?(historyKey: String)
  {
    for kind in Self.charted where kind.historyKey == historyKey
    {
      self = kind
      return
    }
    return nil
  }
}

#if DEBUG
extension ReadingHistory
{
  /// Seven days of made-up readings for `-demo` launches. Kept in memory only.
  static func demo() -> ReadingHistory
  {
    let history = ReadingHistory(fileURL: nil)
    let now = Date.now.timeIntervalSince1970
    let start = now - window
    // Three hours with the app closed on the third day, to show how a gap looks.
    let gapStart = start + 2.5 * 86_400
    let gap = gapStart...(gapStart + 3 * 3_600)
    var seeded: [Key: [Sample]] = [:]
    for (index, device) in SampleData.devices.enumerated()
    {
      // A device that stopped responding has no samples for its last five hours.
      let end = device.isReachable ? now : now - 5 * 3_600
      func samples(_ value: (TimeInterval) -> Double) -> [Sample]
      {
        var result: [Sample] = []
        var time = start
        while time <= end
        {
          if !gap.contains(time)
          {
            result.append(Sample(time: time, value: value(time)))
          }
          time += 5 * 60
        }
        return result
      }
      for reading in device.readings
      {
        guard let base = reading.value, reading.kind.historyKey != nil else
        {
          continue
        }
        seeded[Key(device: device.id, quantity: .reading(reading.kind))] = samples
        {
          time in
          demoValue(reading.kind, base: base, time: time, seed: Double(index))
        }
      }
      if let level = device.battery?.level
      {
        // Three percent over the week, in whole-percent steps.
        seeded[Key(device: device.id, quantity: .battery)] = samples
        {
          time in
          min(100, (Double(level) + 3 * (now - time) / window).rounded())
        }
      }
    }
    history.lock.withLock
    {
      history.series = seeded
      history.firstRecorded = start
    }
    history.isFrozen = true
    return history
  }

  private static func demoValue(_ kind: Reading.Kind, base: Double, time: TimeInterval, seed: Double) -> Double
  {
    let local = time + Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: time)))
    let dayFraction = local.truncatingRemainder(dividingBy: 86_400) / 86_400
    let daily = sin(2 * Double.pi * (dayFraction - 0.375))
    let wobble = sin(time / 2_700 + seed) * 0.5 + sin(time / 9_100 + seed * 2) * 0.5
    switch kind
    {
    case .temperature:
      return base + 1.4 * daily + 0.35 * wobble
    case .humidity:
      return base - 5 * daily + 1.5 * wobble
    case .light:
      let daylight = sin(Double.pi * (dayFraction - 0.27) / 0.5)
      return daylight > 0 ? base * 2.2 * daylight * (0.85 + 0.15 * wobble) : 0.4
    default:
      return base * (1 + 0.12 * daily + 0.05 * wobble)
    }
  }
}
#endif
