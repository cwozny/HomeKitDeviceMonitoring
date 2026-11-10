import Foundation
import HomeKit
import Observation
import os
import UIKit

/// Reads accessories from Apple Home and publishes value snapshots for the dashboard.
@MainActor
@Observable
final class HomeStore: NSObject
{
  enum Phase
  {
    case loading
    case notAuthorized
    case noHomes
    case ready
  }

  private(set) var phase = Phase.loading
  private(set) var devices: [DeviceSnapshot] = []
  /// When the app last got information from HomeKit: a change that HomeKit sent, or a read.
  private(set) var lastUpdate: Date?

  @ObservationIgnored private var manager: HMHomeManager?
  @ObservationIgnored private var hasReceivedHomes = false
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var isDemo = false
  /// When HomeKit last pushed a change, to find long pauses.
  @ObservationIgnored private var lastPush: Date?
  /// True while the app signs up again for changes, so that another long pause doesn't start a second round.
  @ObservationIgnored private var isSigningUpAgain = false

  /// Records HomeKit problems that the app works around without showing them. To read them on the host:
  /// log show --predicate 'subsystem == "<bundle ID>"' --last 1d
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HomeSensors", category: "HomeKit")
  /// A longer pause between pushes is logged, and then the app signs up again for changes. The history records
  /// samples only when something changes, so a pause of more than 45 minutes breaks the chart lines.
  private static let longPause: TimeInterval = 10 * 60

  static func forLaunch() -> HomeStore
  {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-demo")
    {
      return demo()
    }
    #endif
    return HomeStore()
  }

  func start()
  {
    guard manager == nil, !isDemo else
    {
      return
    }
    let manager = HMHomeManager()
    manager.delegate = self
    self.manager = manager
    // The log records each time the app goes to the background and comes back, to help explain gaps in the
    // history. HomeKit stops sending changes only while the app isn't visible, not whenever it's in the background.
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  @objc private func didEnterBackground()
  {
    Self.logger.notice("The app went to the background")
  }

  @objc private func willEnterForeground()
  {
    Self.logger.notice("The app is in the foreground")
  }

  /// Reads every tracked characteristic and turns on change notifications.
  func refresh() async
  {
    guard let manager, !isRefreshing else
    {
      return
    }
    isRefreshing = true
    let accessories = manager.homes.flatMap(\.accessories)
    await withTaskGroup(of: Void.self)
    {
      group in
      for accessory in accessories
      {
        group.addTask
        {
          await self.load(accessory)
        }
      }
    }
    isRefreshing = false
  }

  /// Reads one accessory's characteristics in sequence, which is gentler on sleepy Thread devices.
  private func load(_ accessory: HMAccessory) async
  {
    var received = false
    for characteristic in HomeKitMapping.trackedCharacteristics(of: accessory)
    {
      let item = "\(accessory.name) \(characteristic.localizedDescription)"
      let properties = characteristic.properties
      if properties.contains(HMCharacteristicPropertyReadable)
      {
        let before = characteristic.value as? NSObject
        do
        {
          try await characteristic.readValue()
          received = true
          if let before, let after = characteristic.value as? NSObject, !before.isEqual(after)
          {
            // A push carries every change, so either a push was lost or the device wasn't responding.
            Self.logger.notice("A read changed \(item, privacy: .public) from \(before.description, privacy: .public) to \(after.description, privacy: .public)")
          }
        }
        catch
        {
          // The value stays as it was. A later read or a pushed change updates it.
          Self.logger.error("Couldn't read \(item, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
      }
      if properties.contains(HMCharacteristicPropertySupportsEventNotification) && !characteristic.isNotificationEnabled
      {
        do
        {
          try await characteristic.enableNotification(true)
        }
        catch
        {
          // Tried again the next time the app loads this device, for example when it reconnects, and after a long pause.
          Self.logger.error("Couldn't turn on notifications for \(item, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
      }
    }
    if received
    {
      lastUpdate = .now
    }
    rebuild()
  }

  /// Signs up again for the changes of every tracked characteristic. This repairs a sign-up that the home hub lost,
  /// for example when the primary home hub changed while this Mac couldn't learn about it. Then HomeKit sent only the
  /// periodic status of the hub, with a long pause before each update.
  private func signUpAgain() async
  {
    guard let manager, !isSigningUpAgain else
    {
      return
    }

    isSigningUpAgain = true
    Self.logger.notice("Turning notifications off and on again, so that the home hub sends changes again")
    let accessories = manager.homes.flatMap(\.accessories)
    await withTaskGroup(of: Void.self)
    {
      group in
      for accessory in accessories
      {
        group.addTask
        {
          await self.signUpAgain(for: accessory)
        }
      }
    }

    isSigningUpAgain = false
  }

  /// Signs up again for the changes of one device, one characteristic at a time.
  private func signUpAgain(for accessory: HMAccessory) async
  {
    var switches: [any NotificationSwitch] = []
    for characteristic in HomeKitMapping.trackedCharacteristics(of: accessory)
    {
      if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
      {
        switches.append(characteristic)
      }
    }

    for failure in await Self.signUpAgain(switches)
    {
      Self.logger.error("Couldn't turn notifications off and on for \(failure.name, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
    }
  }

  /// Turns each notification off and on again, in turn, and returns the names and errors of those that failed.
  /// HomeKit signs up with the home hub when a notification turns on. Turning on a notification that HomeKit thinks
  /// is on doesn't reach the hub. A notification that stays off turns on after the next long pause, or when its
  /// device responds again.
  static func signUpAgain(_ switches: [any NotificationSwitch]) async -> [(name: String, error: Error)]
  {
    var failures: [(name: String, error: Error)] = []
    for item in switches
    {
      do
      {
        if item.isNotificationEnabled
        {
          try await item.enableNotification(false)
        }

        try await item.enableNotification(true)
      }
      catch
      {
        failures.append((item.logName, error))
      }
    }

    return failures
  }

  /// The whole minutes of a pause between pushes that is longer than `longPause`.
  /// Nil for a shorter pause, and for the first push, which has no pause before it.
  static func longPauseMinutes(from lastPush: Date?, to now: Date) -> Int?
  {
    guard let lastPush else
    {
      return nil
    }

    let pause = now.timeIntervalSince(lastPush)
    return pause > longPause ? Int(pause / 60) : nil
  }

  private func attachDelegates()
  {
    guard let manager else
    {
      return
    }
    for home in manager.homes
    {
      home.delegate = self
      for accessory in home.accessories
      {
        accessory.delegate = self
      }
    }
  }

  private func rebuild()
  {
    guard let manager else
    {
      return
    }
    let status = manager.authorizationStatus
    if status.contains(.restricted) || (status.contains(.determined) && !status.contains(.authorized))
    {
      phase = .notAuthorized
      devices = []
      return
    }
    guard hasReceivedHomes else
    {
      phase = .loading
      return
    }
    let homes = manager.homes
    var snapshots: [DeviceSnapshot] = []
    for home in homes
    {
      for accessory in home.accessories
      {
        if let snapshot = DeviceSnapshot(accessory: accessory, home: home)
        {
          snapshots.append(snapshot)
        }
      }
    }
    devices = snapshots
    phase = homes.isEmpty ? .noHomes : .ready
  }
}

extension HomeStore: @preconcurrency HMHomeManagerDelegate
{
  func homeManagerDidUpdateHomes(_ manager: HMHomeManager)
  {
    Self.logger.notice("HomeKit loaded the homes. Reading every device.")
    hasReceivedHomes = true
    attachDelegates()
    rebuild()
    Task
    {
      await refresh()
    }
  }

  func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus)
  {
    rebuild()
  }

  func homeManager(_ manager: HMHomeManager, didAdd home: HMHome)
  {
    attachDelegates()
    rebuild()
    // A shared home arrives with its accessories. Read them and turn on their notifications.
    for accessory in home.accessories
    {
      Task
      {
        await load(accessory)
      }
    }
  }

  func homeManager(_ manager: HMHomeManager, didRemove home: HMHome)
  {
    rebuild()
  }
}

extension HomeStore: @preconcurrency HMHomeDelegate
{
  func homeDidUpdateName(_ home: HMHome)
  {
    rebuild()
  }

  func home(_ home: HMHome, didAdd accessory: HMAccessory)
  {
    accessory.delegate = self
    Task
    {
      await load(accessory)
    }
  }

  func home(_ home: HMHome, didRemove accessory: HMAccessory)
  {
    rebuild()
  }

  func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory)
  {
    rebuild()
  }

  func home(_ home: HMHome, didUpdateNameFor room: HMRoom)
  {
    rebuild()
  }
}

extension HomeStore: @preconcurrency HMAccessoryDelegate
{
  func accessoryDidUpdateName(_ accessory: HMAccessory)
  {
    rebuild()
  }

  func accessoryDidUpdateReachability(_ accessory: HMAccessory)
  {
    rebuild()
    if accessory.isReachable
    {
      Self.logger.notice("\(accessory.name, privacy: .public) is responding again")
      Task
      {
        await load(accessory)
      }
    }
    else
    {
      Self.logger.notice("\(accessory.name, privacy: .public) stopped responding")
    }
  }

  func accessoryDidUpdateServices(_ accessory: HMAccessory)
  {
    Task
    {
      await load(accessory)
    }
  }

  func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic)
  {
    let now = Date.now
    if let minutes = Self.longPauseMinutes(from: lastPush, to: now)
    {
      Self.logger.notice("No push came for \(minutes) minutes")
      // After a lost sign-up, a push like this one is often a periodic status update from the home hub.
      Task
      {
        await signUpAgain()
      }
    }

    lastPush = now
    lastUpdate = now
    rebuild()
  }
}

/// A characteristic whose change notifications the app can turn on and off. HMCharacteristic is one, and the tests
/// use a stand-in.
protocol NotificationSwitch: AnyObject
{
  /// The names of the device and the characteristic, for the log.
  var logName: String
  {
    get
  }

  var isNotificationEnabled: Bool
  {
    get
  }

  func enableNotification(_ enable: Bool) async throws
}

extension HMCharacteristic: NotificationSwitch
{
  var logName: String
  {
    "\(service?.accessory?.name ?? "A device") \(localizedDescription)"
  }
}

#if DEBUG
extension HomeStore
{
  /// Sample data for tests and `-demo` launches. Never touches HomeKit.
  static func demo() -> HomeStore
  {
    let store = HomeStore()
    store.isDemo = true
    store.devices = SampleData.devices
    store.lastUpdate = .now
    store.phase = .ready
    return store
  }
}
#endif
