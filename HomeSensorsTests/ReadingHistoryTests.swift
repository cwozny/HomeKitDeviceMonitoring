import Foundation
import Testing
@testable import HomeSensors

@Suite("Reading history")
struct ReadingHistoryTests
{
  /// An hour ago, on a bucket boundary. Buckets follow the clock, and the history file stores whole seconds.
  private let start = Date(
    timeIntervalSince1970: ((Date.now.timeIntervalSince1970 - 3_600) / ReadingHistory.bucketSeconds).rounded(.down) * ReadingHistory.bucketSeconds
  )
  private let deviceID = UUID()

  @Test("Records first values, changes after a minute, and unchanged values every 10 minutes")
  func recordingRules() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    let history = ReadingHistory(fileURL: file)
    history.record([sensor(temperature: 20, humidity: 50)], at: start)
    // A repeated value and a change within a minute are not recorded.
    history.record([sensor(temperature: 20, humidity: 50)], at: start + 30)
    history.record([sensor(temperature: 21, humidity: 50)], at: start + 45)
    // A change after a minute is recorded.
    history.record([sensor(temperature: 21, humidity: 50)], at: start + 90)
    // Nothing is recorded while the device isn't responding.
    history.record([sensor(temperature: 22, humidity: 50, reachable: false)], at: start + 200)
    // After 10 minutes, unchanged values are recorded again.
    history.record([sensor(temperature: 21, humidity: 50)], at: start + 720)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    // Temperature at 0 s, 90 s, and 12 minutes; humidity at 0 s and 12 minutes. Contact states aren't charted.
    #expect(lines.count == 5)
    for line in lines
    {
      #expect(line.split(separator: "\t").count == 4)
    }
  }

  @Test("Reloads saved readings when the app starts again")
  func reloadsSavedReadings() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    ReadingHistory(fileURL: file).record([sensor(temperature: 20, humidity: 50)], at: start)
    let payload = try decode(ReadingHistory(fileURL: file).payload(at: start + 3_600))
    #expect(payload.series.map(\.kind).sorted() == ["humidity", "temperature"])
    #expect(payload.recordingSince == Int(start.timeIntervalSince1970))
  }

  @Test("Averages readings into 10-minute buckets in the Mac's temperature unit")
  func averagesIntoBuckets() throws
  {
    let history = ReadingHistory(fileURL: nil)
    history.record([sensor(temperature: 20, humidity: 50)], at: start)
    history.record([sensor(temperature: 21, humidity: 50)], at: start + 90)
    history.record([sensor(temperature: 21, humidity: 50)], at: start + 720)
    // `start` is on a bucket boundary, so the first two readings share a bucket.
    let payload = try decode(history.payload(at: start + 3_600))
    let temperatures = payload.series.filter
    {
      $0.kind == "temperature"
    }
    let temperature = try #require(temperatures.first)
    let unit = UnitTemperature(forLocale: .current, usage: .weather)
    let average = Measurement(value: 20.5, unit: UnitTemperature.celsius).converted(to: unit).value
    #expect(temperature.unit == unit.symbol)
    #expect(temperature.points.count == 2)
    #expect(abs(temperature.points[0][1] - (average * 10).rounded() / 10) < 0.001)
  }

  @Test("Moves readings from before the first of the 7 days to the archive and drops damaged lines when it loads the file")
  func archivesOldLinesWhenLoading() throws
  {
    let file = temporaryFile()
    let archive = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: archive)
    }
    ReadingHistory(fileURL: file, archiveURL: archive).record([sensor(temperature: 20, humidity: 50)], at: start)
    let old = "\(Int(Date.now.timeIntervalSince1970 - 9 * 86_400))\t\(deviceID.uuidString)\ttemperature\t19.5"
    let handle = try FileHandle(forWritingTo: file)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data((old + "\nnot a reading\n").utf8))
    try handle.close()
    _ = ReadingHistory(fileURL: file, archiveURL: archive)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let archived = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n")
    #expect(archived.map(String.init) == [old])
  }

  @Test("Keeps samples from before the first of the 7 days when it can't write the archive, so a later cleanup can try again")
  func keepsSamplesWhenArchiveFails() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    // In a folder that doesn't exist, so the archive can't be written.
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent("HomeSensorsTests-\(UUID().uuidString)/archive.tsv")
    ReadingHistory(fileURL: file, archiveURL: archive).record([sensor(temperature: 20, humidity: 50)], at: start)
    let old = "\(Int(Date.now.timeIntervalSince1970 - 9 * 86_400))\t\(deviceID.uuidString)\ttemperature\t19.5\n"
    let handle = try FileHandle(forWritingTo: file)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(old.utf8))
    try handle.close()
    // Loading keeps the old line, and so does the cleanup while the app runs.
    let history = ReadingHistory(fileURL: file, archiveURL: archive)
    history.record([sensor(temperature: 21, humidity: 51)], at: start + 9 * 86_400)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 5)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
  }

  @Test("Moves samples to the archive while the app runs, after their day is before the first of the 7 days")
  func archivesWhileRunning() throws
  {
    let file = temporaryFile()
    let archive = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: archive)
    }
    let history = ReadingHistory(fileURL: file, archiveURL: archive)
    history.record([sensor(temperature: 20, humidity: 50)], at: start)
    // Nine days later, the day of the first samples is before the first of the 7 days, and the 6-hourly cleanup is due.
    history.record([sensor(temperature: 21, humidity: 51)], at: start + 9 * 86_400)
    let archived = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n")
    let kept = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(archived.count == 2)
    #expect(kept.count == 2)
    for line in archived
    {
      #expect(line.hasPrefix("\(Int(start.timeIntervalSince1970))\t"))
    }
  }

  @Test("Keeps the time that recording started after the cleanup removes the first samples, so a pause at the start of the window doesn't shorten the charts")
  func keepsRecordingStartAfterCleanup() throws
  {
    let history = ReadingHistory(fileURL: nil)
    history.record([sensor(temperature: 20, humidity: 50)], at: start)
    // Eight days later, after a day with no readings, the window starts in that pause.
    let later = start + 8 * 86_400
    history.record([sensor(temperature: 21, humidity: 51)], at: later)
    let payload = try decode(history.payload(at: later))
    #expect(payload.recordingSince == Int(start.timeIntervalSince1970))
  }

  @Test("Finds the time that recording started in the archive after a launch moves the first samples there")
  func findsRecordingStartInArchive() throws
  {
    let file = temporaryFile()
    let archive = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: archive)
    }

    let now = Int(Date.now.timeIntervalSince1970)
    let first = now - 9 * 86_400
    // No readings in the first day of the window.
    let lines = [
      "\(first)\t\(deviceID.uuidString)\thumidity\t50",
      "\(now - 6 * 86_400)\t\(deviceID.uuidString)\thumidity\t51",
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    // The first launch moves the oldest sample to the archive. The next launch finds it only there.
    let firstLaunch = try decode(ReadingHistory(fileURL: file, archiveURL: archive).payload())
    let nextLaunch = try decode(ReadingHistory(fileURL: file, archiveURL: archive).payload())
    #expect(firstLaunch.recordingSince == first)
    #expect(nextLaunch.recordingSince == first)
  }

  @Test("Gives the low and high of each full day, also for the first day, which starts before the 7 days")
  func dailyLowAndHighCoverFullDays() throws
  {
    let calendar = Calendar.current
    // In the afternoon, so the 7 days start in the afternoon of the first day.
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 15)))
    let windowStart = now - ReadingHistory.window
    let history = ReadingHistory(fileURL: nil)
    // The lowest humidity of the first day is in its morning, before the 7 days start.
    history.record([sensor(temperature: 20, humidity: 30, battery: 90)], at: calendar.startOfDay(for: windowStart) + 6 * 3_600)
    history.record([sensor(temperature: 20, humidity: 50, battery: 90)], at: windowStart + 3_600)
    history.record([sensor(temperature: 20, humidity: 60, battery: 90)], at: now - 3_600)
    let payload = try decode(history.payload(at: now))
    let humidities = payload.series.filter
    {
      $0.kind == "humidity"
    }
    let humidity = try #require(humidities.first)
    let days = try #require(humidity.days)
    #expect(days.map(\.date) == ["2026-03-13", "2026-03-20"])
    #expect(days[0].low == 30)
    #expect(days[0].high == 50)
    #expect(days[0].average == 40)
    #expect(days[1].low == 60)
    // The chart still starts when the 7 days start.
    #expect(humidity.points.count == 2)
    // The page shows no low and high for the battery level.
    let batteries = payload.series.filter
    {
      $0.kind == "battery"
    }
    let battery = try #require(batteries.first)
    #expect(battery.days == nil)
    #expect(battery.low == nil)
  }

  @Test("Gives the lowest and highest readings, not the lowest and highest 10-minute averages")
  func lowAndHighComeFromReadings() throws
  {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 15)))
    let history = ReadingHistory(fileURL: nil)
    // In the same 10-minute bucket, so the chart shows only their average.
    history.record([sensor(temperature: 20, humidity: 30)], at: now - 3_600)
    history.record([sensor(temperature: 20, humidity: 50)], at: now - 3_600 + 90)
    let payload = try decode(history.payload(at: now))
    let humidities = payload.series.filter
    {
      $0.kind == "humidity"
    }
    let humidity = try #require(humidities.first)
    #expect(humidity.points.count == 1)
    #expect(humidity.points.first?.last == 40)
    #expect(humidity.low == 30)
    #expect(humidity.high == 50)
    let day = try #require(humidity.days?.last)
    #expect(day.low == 30)
    #expect(day.high == 50)
    #expect(day.average == 40)
  }

  @Test("Keeps the samples of the whole first day in the file when it loads it, and moves older samples to the archive")
  func keepsFirstDayWhenLoading() throws
  {
    let file = temporaryFile()
    let archive = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: archive)
    }

    let now = Date.now.timeIntervalSince1970
    let firstDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now - ReadingHistory.window))
    // The sample at the start of the first day is older than 7 days, but its day is one of the 7.
    let lines = [
      "\(Int(now) - 9 * 86_400)\t\(deviceID.uuidString)\thumidity\t40.5",
      "\(Int(firstDay.timeIntervalSince1970))\t\(deviceID.uuidString)\thumidity\t45.5",
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    _ = ReadingHistory(fileURL: file, archiveURL: archive)
    let kept = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    let archived = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(kept == [lines[1]])
    #expect(archived == [lines[0]])
  }

  @Test("Saves the battery level and charts it last, up to 100 percent and without a low and high")
  func chartsBatteryLevel() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    ReadingHistory(fileURL: file).record([sensor(temperature: 20, humidity: 50, battery: 95)], at: start)
    let payload = try decode(ReadingHistory(fileURL: file).payload(at: start + 3_600))
    #expect(payload.series.map(\.kind) == ["temperature", "humidity", "battery"])
    let battery = try #require(payload.series.last)
    #expect(battery.unit == "%")
    #expect(battery.maximum == 100)
    #expect(!battery.showsLowHigh)
    #expect(battery.points == [[start.timeIntervalSince1970, 95]])
    let temperature = try #require(payload.series.first)
    #expect(temperature.maximum == nil)
    #expect(temperature.showsLowHigh)
  }

  @Test("Lists the series by kind in chart order, then by device, so the page's filter keeps that order")
  func listsSeriesByKind() throws
  {
    // This device sorts first by its ID, so listing by device first would put its battery level first.
    let door = makeDevice("Door sensor", id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000")), battery: Battery(level: 90))
    let history = ReadingHistory(fileURL: nil)
    history.record([door, sensor(temperature: 20, humidity: 50, battery: 95)], at: start)
    let payload = try decode(history.payload(at: start + 3_600))
    #expect(payload.series.map(\.kind) == ["temperature", "humidity", "battery", "battery"])
  }

  @Test("Gives the same points whenever the page asks, because buckets follow the clock")
  func bucketsFollowTheClock() throws
  {
    let history = ReadingHistory(fileURL: nil)
    history.record([sensor(temperature: 20, humidity: 50)], at: start + 240)
    history.record([sensor(temperature: 20, humidity: 54)], at: start + 420)
    history.record([sensor(temperature: 20, humidity: 54)], at: start + 1_080)
    let first = try decode(history.payload(at: start + 3_600)).series.map(\.points)
    let later = try decode(history.payload(at: start + 3_900)).series.map(\.points)
    #expect(first == later)
  }

  @Test("Ignores lines with values or times it can't use when it loads the file")
  func ignoresUnusableLines() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    let time = Int(start.timeIntervalSince1970)
    let device = deviceID.uuidString
    let lines = [
      "\(time)\t\(device)\thumidity\t50",
      "\(time + 60)\t\(device)\thumidity\tnan",
      "\(time + 120)\t\(device)\thumidity\tinf",
      "\(time + 180)\t\(device)\thumidity\t1e400",
      "inf\t\(device)\thumidity\t51",
      "\(Int(Date.now.timeIntervalSince1970) + 86_400)\t\(device)\thumidity\t52",
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let points = try decode(ReadingHistory(fileURL: file).payload(at: start + 3_600)).series.map(\.points)
    #expect(points == [[[Double(time), 50]]])
    let kept = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(kept.count == 1)
  }

  @Test("Keeps recording after the clock goes back")
  func recordsAfterClockGoesBack() throws
  {
    let history = ReadingHistory(fileURL: nil)
    history.record([sensor(temperature: 20, humidity: 50)], at: start + 1_200)
    // The clock goes back 10 minutes: the reading from the future is dropped, and the new one is recorded.
    history.record([sensor(temperature: 20, humidity: 55)], at: start + 600)
    let payload = try decode(history.payload(at: start + 660))
    let humidities = payload.series.filter
    {
      $0.kind == "humidity"
    }
    let humidity = try #require(humidities.first)
    #expect(humidity.points == [[start.timeIntervalSince1970 + 600, 55]])
  }

  @Test("The page data names each reading's history series, because a level and its detected flag share a name")
  func readingsNameTheirSeries()
  {
    let readings = [
      Reading(kind: .carbonDioxideDetected, value: 0),
      Reading(kind: .carbonDioxide, value: 712),
    ]
    let info = WebPayload.DeviceInfo(device: makeDevice("Air monitor", readings: readings))
    let kinds = info.readings.map(\.kind)
    #expect(kinds == [nil, "co2"])
  }

  private func sensor(temperature: Double, humidity: Double, battery: Int? = nil, reachable: Bool = true) -> DeviceSnapshot
  {
    let readings = [
      Reading(kind: .temperature, value: temperature),
      Reading(kind: .humidity, value: humidity),
      Reading(kind: .contact, value: 1),
    ]
    var power: Battery?
    if let battery
    {
      power = Battery(level: battery)
    }
    return makeDevice("Climate sensor", id: deviceID, battery: power, readings: readings, reachable: reachable)
  }

  private func temporaryFile() -> URL
  {
    FileManager.default.temporaryDirectory.appendingPathComponent("HomeSensorsTests-\(UUID().uuidString).tsv")
  }

  private func decode(_ data: Data) throws -> DecodedPayload
  {
    try JSONDecoder().decode(DecodedPayload.self, from: data)
  }
}

/// The parts of the history JSON that the tests read.
private struct DecodedPayload: Decodable
{
  struct Series: Decodable
  {
    var kind: String
    var unit: String
    var maximum: Double?
    var showsLowHigh: Bool
    var low: Double?
    var high: Double?
    var points: [[Double]]
    var days: [Day]?
  }

  struct Day: Decodable
  {
    var date: String
    var low: Double
    var high: Double
    var average: Double
  }

  var recordingSince: Int?
  var series: [Series]
}
