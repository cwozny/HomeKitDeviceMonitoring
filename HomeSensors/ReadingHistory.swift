import Foundation

/// Records numeric sensor readings so the web page can chart the last 7 days.
/// HomeKit keeps no history, so the record starts when the app first runs.
/// Recording happens on the main actor; the web server reads payloads on its own queue.
final class ReadingHistory: @unchecked Sendable
{
  struct Sample
  {
    var time: TimeInterval
    var value: Double
  }

  struct Key: Hashable
  {
    var device: UUID
    var kind: Reading.Kind
  }

  static let window: TimeInterval = 7 * 24 * 60 * 60
  static let bucketSeconds: TimeInterval = 10 * 60
  /// A changed value is recorded at most this often, which keeps chatty sensors in check.
  private static let minimumSpacing: TimeInterval = 60
  /// An unchanged value is recorded this often, so lines continue and gaps mean missing data.
  private static let heartbeat: TimeInterval = 10 * 60
  private static let pruneInterval: TimeInterval = 6 * 60 * 60

  private let fileURL: URL?
  private let lock = NSLock()
  private var series: [Key: [Sample]] = [:]
  private var lastPrune: TimeInterval
  private var isFrozen = false

  init(fileURL: URL?)
  {
    self.fileURL = fileURL
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
    return ReadingHistory(fileURL: defaultFileURL())
  }

  /// ~/Library/Application Support/<bundle ID>/history.tsv
  private static func defaultFileURL() -> URL?
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
    return folder.appendingPathComponent("history.tsv")
  }

  /// Adds the charted readings of devices that are responding. Call whenever the devices change.
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
        for reading in device.readings where reading.kind.historyKey != nil
        {
          guard let value = reading.value, value.isFinite else
          {
            continue
          }
          let key = Key(device: device.id, kind: reading.kind)
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
        }
      }
    }
    append(added)
    if now - lastPrune >= Self.pruneInterval
    {
      prune(now: now)
    }
  }

  /// The JSON behind the History view: each series for the last 7 days, averaged into 10-minute buckets.
  func payload(at date: Date = .now) -> Data
  {
    let now = date.timeIntervalSince1970
    let start = now - Self.window
    let snapshot = lock.withLock
    {
      series
    }
    let temperatureUnit = UnitTemperature(forLocale: .current, usage: .weather)
    let keys = snapshot.keys.sorted
    {
      ($0.device.uuidString, $0.kind.rawValue) < ($1.device.uuidString, $1.kind.rawValue)
    }
    var list: [HistoryPayload.Series] = []
    var earliest: TimeInterval?
    for key in keys
    {
      let recent = (snapshot[key] ?? []).drop(while: { $0.time < start })
      guard let first = recent.first, let name = key.kind.historyKey, let style = ChartStyle(kind: key.kind, temperatureUnit: temperatureUnit) else
      {
        continue
      }
      earliest = min(earliest ?? first.time, first.time)
      list.append(HistoryPayload.Series(
        device: key.device.uuidString,
        kind: name,
        name: style.name,
        unit: style.unit,
        decimals: style.decimals,
        minimumSpan: style.minimumSpan,
        nonNegative: style.nonNegative,
        points: Self.buckets(recent, start: start, convert: style.convert)
      ))
    }
    let payload = HistoryPayload(
      now: Int(now),
      start: Int(start),
      recordingSince: earliest.map { Int($0) },
      bucketSeconds: Int(Self.bucketSeconds),
      series: list
    )
    return (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
  }

  /// Averages samples into fixed buckets and returns [time, value] pairs in display units.
  private static func buckets(_ samples: ArraySlice<Sample>, start: TimeInterval, convert: (Double) -> Double) -> [[Double]]
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
      let bucket = Int((sample.time - start) / bucketSeconds)
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
      if let kind = key.kind.historyKey
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
    let cutoff = Date.now.timeIntervalSince1970 - Self.window
    var loaded: [Key: [Sample]] = [:]
    var dropped = 0
    for line in text.split(separator: "\n")
    {
      let fields = line.split(separator: "\t")
      guard fields.count == 4,
        let time = Double(fields[0]),
        let device = UUID(uuidString: String(fields[1])),
        let kind = Reading.Kind(historyKey: String(fields[2])),
        let value = Double(fields[3]),
        time >= cutoff
      else
      {
        dropped += 1
        continue
      }
      loaded[Key(device: device, kind: kind), default: []].append(Sample(time: time, value: value))
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
    }
    if dropped > 0
    {
      rewrite(loaded)
    }
  }

  private func append(_ entries: [(Key, Sample)])
  {
    guard let fileURL, !entries.isEmpty else
    {
      return
    }
    let data = Self.lines(entries)
    guard let handle = try? FileHandle(forWritingTo: fileURL) else
    {
      try? data.write(to: fileURL)
      return
    }
    defer
    {
      try? handle.close()
    }
    do
    {
      _ = try handle.seekToEnd()
      try handle.write(contentsOf: data)
    }
    catch
    {
      // Only these samples are lost; recording continues.
    }
  }

  private func prune(now: TimeInterval)
  {
    lastPrune = now
    let cutoff = now - Self.window
    let kept: [Key: [Sample]] = lock.withLock
    {
      var result: [Key: [Sample]] = [:]
      for (key, samples) in series
      {
        let recent = Array(samples.drop(while: { $0.time < cutoff }))
        if !recent.isEmpty
        {
          result[key] = recent
        }
      }
      series = result
      return result
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
    /// [seconds since 1970, value in `unit`] pairs, oldest first.
    var points: [[Double]]
  }

  var now: Int
  var start: Int
  /// When the oldest sample in the window was recorded. Nil until anything is recorded.
  var recordingSince: Int?
  var bucketSeconds: Int
  var series: [Series]
}

/// How the History view labels and scales one kind of reading.
struct ChartStyle
{
  var name: String
  var unit: String
  var decimals: Int
  var minimumSpan: Double
  var nonNegative = true
  var convert: (Double) -> Double = { $0 }

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
      convert = { Measurement(value: $0, unit: UnitTemperature.celsius).converted(to: temperatureUnit).value }
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
    guard let kind = Self.charted.first(where: { $0.historyKey == historyKey }) else
    {
      return nil
    }
    self = kind
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
      for reading in device.readings
      {
        guard let base = reading.value, reading.kind.historyKey != nil else
        {
          continue
        }
        var samples: [Sample] = []
        var time = start
        while time <= end
        {
          if !gap.contains(time)
          {
            samples.append(Sample(time: time, value: demoValue(reading.kind, base: base, time: time, seed: Double(index))))
          }
          time += 5 * 60
        }
        seeded[Key(device: device.id, kind: reading.kind)] = samples
      }
    }
    history.lock.withLock
    {
      history.series = seeded
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
