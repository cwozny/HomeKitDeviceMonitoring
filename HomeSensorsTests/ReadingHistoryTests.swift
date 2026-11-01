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

  @Test("Drops readings older than 7 days and damaged lines when it loads the file")
  func dropsOldAndDamagedLines() throws
  {
    let file = temporaryFile()
    defer
    {
      try? FileManager.default.removeItem(at: file)
    }
    ReadingHistory(fileURL: file).record([sensor(temperature: 20, humidity: 50)], at: start)
    let old = "\(Int(Date.now.timeIntervalSince1970 - 8 * 86_400))\t\(deviceID.uuidString)\ttemperature\t19.5\nnot a reading\n"
    let handle = try FileHandle(forWritingTo: file)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(old.utf8))
    try handle.close()
    _ = ReadingHistory(fileURL: file)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
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
    let info = WebPayload.DeviceInfo(device: makeDevice("Air monitor", readings: readings), showHome: false)
    let kinds = info.readings.map(\.kind)
    #expect(kinds == [nil, "co2"])
  }

  private func sensor(temperature: Double, humidity: Double, reachable: Bool = true) -> DeviceSnapshot
  {
    let readings = [
      Reading(kind: .temperature, value: temperature),
      Reading(kind: .humidity, value: humidity),
      Reading(kind: .contact, value: 1),
    ]
    return makeDevice("Climate sensor", id: deviceID, readings: readings, reachable: reachable)
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
    var points: [[Double]]
  }

  var recordingSince: Int?
  var series: [Series]
}
