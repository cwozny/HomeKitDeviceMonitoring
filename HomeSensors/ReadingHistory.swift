import Foundation
import os

/// Records numeric sensor readings and battery levels. The web page charts the readings of the last 7 days.
/// The daily low and high are for full days, so the samples of the whole first day of the 7 stay too.
/// Older samples move to an archive file, and lines that the app can't use move to a rejected file.
/// The app only appends to those two files, so no sample is lost.
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

    /// Stable name in the history file and, for a reading, in the page data. Nil for readings the History view doesn't chart.
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

  /// Nil when the history is in memory only, also after a file that can't be read couldn't move aside.
  private var fileURL: URL?
  /// Receives the samples from before the first day of the 7 days. Without it, they're deleted.
  private let archiveURL: URL?
  /// Receives the lines that the app can't use, such as damaged lines. Without it, they stay in the history file.
  private let rejectedURL: URL?
  private let lock = NSLock()
  private var series: [Key: [Sample]] = [:]
  /// When the app recorded its first sample. That sample can be in the archive.
  private var firstRecorded: TimeInterval?
  /// Lines that the app can't use and couldn't move to the rejected file, each with its line break.
  /// Each rewrite keeps them in the history file, and each cleanup tries to move them again.
  private var unmoved = Data()
  private var lastPrune: TimeInterval
  private var isFrozen = false

  /// Records problems with the history files. To read them on the host:
  /// /usr/bin/log show --predicate 'subsystem == "<bundle ID>" && category == "History"' --last 1d
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HomeSensors", category: "History")

  init(fileURL: URL?, archiveURL: URL? = nil, rejectedURL: URL? = nil)
  {
    self.fileURL = fileURL
    self.archiveURL = archiveURL
    self.rejectedURL = rejectedURL
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
      archiveURL: folder?.appendingPathComponent("history-archive.tsv"),
      rejectedURL: folder?.appendingPathComponent("history-rejected.tsv")
    )
  }

  /// ~/Library/Application Support/<bundle ID>, which holds history.tsv, history-archive.tsv, and history-rejected.tsv.
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

  /// Midnight at the start of the first of the 7 days, on the Mac's calendar.
  /// Samples from then on stay in memory and in the history file. Older samples move to the archive.
  private static func startOfFirstDay(_ now: TimeInterval) -> TimeInterval
  {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now - window)).timeIntervalSince1970
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
    var future: [(Key, Sample)] = []
    lock.withLock
    {
      for device in devices where device.isReachable
      {
        for (quantity, value) in Self.recordedValues(of: device)
        {
          let key = Key(device: device.id, quantity: quantity)
          if let samples = series[key], let last = samples.last, last.time > now
          {
            // The clock went back. Samples from the future would stop recording until it caught up.
            var kept: [Sample] = []
            for sample in samples
            {
              if sample.time > now
              {
                future.append((key, sample))
              }
              else
              {
                kept.append(sample)
              }
            }

            series[key] = kept
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
    if !future.isEmpty
    {
      // They leave the history file, but they aren't deleted.
      if reject(Self.lines(future))
      {
        Self.logger.error("The clock went back. \(future.count) samples from the future moved to the rejected file.")
      }
      else
      {
        Self.logger.error("The clock went back. \(future.count) samples from the future stay in the history file, because they can't move to a rejected file.")
      }

      let current = lock.withLock
      {
        series
      }
      rewrite(current)
    }

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

  /// The JSON behind the History view: each reading's series for the last 7 days, averaged into 10-minute buckets,
  /// its lowest and highest readings, and the low and high of each full day. The battery levels aren't in it.
  func payload(at date: Date = .now) -> Data
  {
    let now = date.timeIntervalSince1970
    let start = now - Self.window
    let firstDay = Self.startOfFirstDay(now)
    let (snapshot, started) = lock.withLock
    {
      (series, firstRecorded)
    }
    let temperatureUnit = UnitTemperature(forLocale: .current, usage: .weather)
    // Only the readings have charts. The battery level changes too little in 7 days, but the file still records it.
    var charted: [(key: Key, kind: Reading.Kind)] = []
    for key in snapshot.keys
    {
      if case .reading(let kind) = key.quantity
      {
        charted.append((key, kind))
      }
    }

    // By kind in chart order, so the page lists the kinds in its filter in that order. Then by device.
    charted.sort
    {
      ($0.kind.rawValue, $0.key.device.uuidString) < ($1.kind.rawValue, $1.key.device.uuidString)
    }
    var list: [HistoryPayload.Series] = []
    for (key, kind) in charted
    {
      let samples = snapshot[key] ?? []
      let recent = samples.filter
      {
        $0.time >= start
      }
      guard !recent.isEmpty, let name = kind.historyKey, let style = ChartStyle(kind: kind, temperatureUnit: temperatureUnit) else
      {
        continue
      }

      // From the readings, because a 10-minute average hides a short low or high.
      var low = Double.infinity
      var high = -Double.infinity
      for sample in recent
      {
        let value = style.convert(sample.value)
        low = min(low, value)
        high = max(high, value)
      }

      // The first day starts before the 7 days, and its low and high are for the full day too.
      let fullDays = samples.filter
      {
        $0.time >= firstDay
      }
      list.append(HistoryPayload.Series(
        device: key.device.uuidString,
        kind: name,
        name: style.name,
        unit: style.unit,
        decimals: style.decimals,
        minimumSpan: style.minimumSpan,
        nonNegative: style.nonNegative,
        low: low,
        high: high,
        points: Self.buckets(recent, convert: style.convert),
        days: Self.days(fullDays, convert: style.convert)
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

  /// The lowest and highest reading of each day on the Mac's calendar, and the average of its 10-minute averages, oldest first.
  private static func days(_ samples: [Sample], convert: (Double) -> Double) -> [HistoryPayload.Day]
  {
    let calendar = Calendar.current
    var days: [HistoryPayload.Day] = []
    var day = Date.distantPast
    var nextDay = -Double.infinity
    var daySamples: [Sample] = []
    func flush()
    {
      if daySamples.isEmpty
      {
        return
      }

      var low = Double.infinity
      var high = -Double.infinity
      for sample in daySamples
      {
        let value = convert(sample.value)
        low = min(low, value)
        high = max(high, value)
      }

      let averages = buckets(daySamples, convert: convert)
      var sum = 0.0
      for point in averages
      {
        sum += point[1]
      }

      days.append(HistoryPayload.Day(date: dateText(day, calendar), low: low, high: high, average: sum / Double(averages.count)))
    }

    for sample in samples
    {
      if sample.time >= nextDay
      {
        flush()
        day = calendar.startOfDay(for: Date(timeIntervalSince1970: sample.time))
        nextDay = calendar.date(byAdding: .day, value: 1, to: day)?.timeIntervalSince1970 ?? .infinity
        daySamples = []
      }

      daySamples.append(sample)
    }

    flush()
    return days
  }

  /// A day on the Mac's calendar as text, such as "2026-11-01".
  private static func dateText(_ day: Date, _ calendar: Calendar) -> String
  {
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
    guard let fileURL else
    {
      return
    }

    let now = Date.now.timeIntervalSince1970
    let data: Data
    do
    {
      data = try Data(contentsOf: fileURL)
    }
    catch
    {
      // No file yet, or one that can't be read. That one moves aside, so a rewrite can't replace it.
      if FileManager.default.fileExists(atPath: fileURL.path)
      {
        setAside(fileURL, readError: error, now: now)
      }

      return
    }

    let cutoff = Self.startOfFirstDay(now)
    var loaded: [Key: [Sample]] = [:]
    var old: [(Key, Sample)] = []
    var first = Self.firstTime(in: archiveURL, now: now)
    var rejected = Data()
    var rejectedCount = 0
    // Line by line, so a damaged byte affects only its own line. A line can also end in a carriage return.
    for rawLine in data.split(separator: UInt8(ascii: "\n"))
    {
      var line = rawLine
      if line.last == UInt8(ascii: "\r")
      {
        line = line.dropLast()
      }

      if line.isEmpty
      {
        continue
      }

      let fields = String(decoding: line, as: UTF8.self).split(separator: "\t")
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
        // A damaged line, a kind that this version doesn't know, or a time in the future.
        rejected.append(rawLine)
        rejected.append(UInt8(ascii: "\n"))
        rejectedCount += 1
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
    var movedRejected = false
    if rejectedCount > 0
    {
      movedRejected = reject(rejected)
      if movedRejected
      {
        Self.logger.error("Moved \(rejectedCount) lines that the app can't use from \(fileURL.lastPathComponent, privacy: .public) to the rejected file.")
      }
      else
      {
        Self.logger.error("Kept \(rejectedCount) lines that the app can't use in \(fileURL.lastPathComponent, privacy: .public), because they can't move to a rejected file.")
      }
    }

    if movedRejected || (archived && !old.isEmpty)
    {
      rewrite(loaded)
    }
  }

  /// Moves a history file that can't be read out of the way, so a rewrite can't replace it. The app then starts a new file.
  /// If the file can't move, the app leaves it alone and keeps the history in memory only.
  private func setAside(_ url: URL, readError: Error, now: TimeInterval)
  {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let stamp = formatter.string(from: Date(timeIntervalSince1970: now))
    let name = url.deletingPathExtension().lastPathComponent + "-unreadable-" + stamp + "." + url.pathExtension
    do
    {
      try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
      Self.logger.error("Couldn't read \(url.lastPathComponent, privacy: .public), so it moved to \(name, privacy: .public): \(readError.localizedDescription, privacy: .public)")
    }
    catch
    {
      fileURL = nil
      Self.logger.error("Couldn't read or move \(url.lastPathComponent, privacy: .public), so the history stays in memory only: \(error.localizedDescription, privacy: .public)")
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

  /// Appends samples from before the first day of the 7 days to the archive, oldest first. False if it couldn't write them.
  private func archive(_ entries: [(Key, Sample)]) -> Bool
  {
    let sorted = entries.sorted
    {
      $0.1.time < $1.1.time
    }
    return append(sorted, to: archiveURL)
  }

  /// False if the samples couldn't be written. Then only these samples are missing from this file, and recording continues.
  @discardableResult
  private func append(_ entries: [(Key, Sample)], to url: URL?) -> Bool
  {
    guard let url, !entries.isEmpty else
    {
      return true
    }

    return Self.appendLines(Self.lines(entries), to: url)
  }

  /// Moves lines that the app can't use to the rejected file. If they can't move, each rewrite keeps them in the history file.
  /// True if they moved.
  @discardableResult
  private func reject(_ lines: Data) -> Bool
  {
    if let rejectedURL, Self.appendLines(lines, to: rejectedURL)
    {
      return true
    }

    unmoved.append(lines)
    return false
  }

  /// Adds lines at the end of a file. False if they weren't added.
  /// If the file doesn't end with a line break, for example after a crash, a line break comes first, so the new lines can't join a damaged line.
  /// A write that fails is cut off again, so the file never ends in a part of a line.
  static func appendLines(_ lines: Data, to url: URL) -> Bool
  {
    appendLines(lines, to: url)
    {
      handle, data in
      try handle.write(contentsOf: data)
    }
  }

  /// The same, with a write that a test can make fail.
  static func appendLines(_ lines: Data, to url: URL, write: (FileHandle, Data) throws -> Void) -> Bool
  {
    guard let handle = try? FileHandle(forUpdating: url) else
    {
      // There's no file yet. A file that is there but can't be opened stays as it is.
      return (try? lines.write(to: url, options: .withoutOverwriting)) != nil
    }

    defer
    {
      try? handle.close()
    }

    var end: UInt64?
    do
    {
      let size = try handle.seekToEnd()
      end = size
      var data = lines
      if size > 0
      {
        try handle.seek(toOffset: size - 1)
        if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")])
        {
          data.insert(UInt8(ascii: "\n"), at: data.startIndex)
        }
      }

      try write(handle, data)
      return true
    }
    catch
    {
      if let end
      {
        try? handle.truncate(atOffset: end)
      }

      return false
    }
  }

  private func prune(now: TimeInterval)
  {
    lastPrune = now
    let cutoff = Self.startOfFirstDay(now)
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
    if !unmoved.isEmpty
    {
      // Another try for the lines that couldn't move to the rejected file.
      let lines = unmoved
      unmoved = Data()
      reject(lines)
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
    // The lines that couldn't move to the rejected file stay, at the start.
    var data = unmoved
    data.append(Self.lines(entries))
    try? data.write(to: fileURL, options: .atomic)
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
    /// The lowest reading in the last 7 days, in `unit`.
    var low: Double
    /// The highest reading in the last 7 days, in `unit`.
    var high: Double
    /// [seconds since 1970, value in `unit`] pairs, oldest first.
    var points: [[Double]]
    /// The low, high, and average of each day, oldest first, for the daily table.
    var days: [Day]
  }

  /// The low, high, and average of one full day, or of today since midnight, in the series' unit.
  struct Day: Encodable
  {
    /// The day on the Mac's calendar, such as "2026-11-01".
    var date: String
    /// The lowest reading of the day.
    var low: Double
    /// The highest reading of the day.
    var high: Double
    /// The average of the day's 10-minute averages.
    var average: Double
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
  /// Set for temperatures, which HomeKit reports in Celsius.
  var temperatureUnit: UnitTemperature?

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
  /// Seven days of made-up readings, from the start of the first day, for `-demo` launches. Kept in memory only.
  static func demo() -> ReadingHistory
  {
    let history = ReadingHistory(fileURL: nil)
    let now = Date.now.timeIntervalSince1970
    // From midnight, so the first day has a full low and high.
    let start = startOfFirstDay(now)
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
