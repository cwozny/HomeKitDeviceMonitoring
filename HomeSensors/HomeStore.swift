import Foundation
import HomeKit
import Observation

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
  private(set) var homeCount = 0
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?

  @ObservationIgnored private var manager: HMHomeManager?
  @ObservationIgnored private var hasReceivedHomes = false
  @ObservationIgnored private var periodicRefresh: Task<Void, Never>?
  @ObservationIgnored private var isDemo = false

  /// Updates arrive as notifications; this periodic re-read is a safety net.
  private static let refreshInterval = Duration.seconds(15 * 60)

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
    periodicRefresh = Task
    {
      [weak self] in
      while !Task.isCancelled
      {
        try? await Task.sleep(for: HomeStore.refreshInterval)
        await self?.refresh()
      }
    }
  }

  /// Re-reads values unless a refresh finished within the last minute.
  func refreshIfStale()
  {
    if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60
    {
      return
    }
    Task
    {
      await refresh()
    }
  }

  /// Reads every tracked characteristic and turns on change notifications.
  func refresh() async
  {
    if isDemo
    {
      lastRefresh = .now
      return
    }
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
    lastRefresh = .now
  }

  /// Reads one accessory's characteristics in sequence, which is gentler on sleepy Thread devices.
  private func load(_ accessory: HMAccessory) async
  {
    for characteristic in HomeKitMapping.trackedCharacteristics(of: accessory)
    {
      let properties = characteristic.properties
      if properties.contains(HMCharacteristicPropertyReadable)
      {
        try? await characteristic.readValue()
      }
      if properties.contains(HMCharacteristicPropertySupportsEventNotification) && !characteristic.isNotificationEnabled
      {
        try? await characteristic.enableNotification(true)
      }
    }
    rebuild()
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
    homeCount = homes.count
    devices = snapshots
    phase = homes.isEmpty ? .noHomes : .ready
  }
}

extension HomeStore: @preconcurrency HMHomeManagerDelegate
{
  func homeManagerDidUpdateHomes(_ manager: HMHomeManager)
  {
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
      Task
      {
        await load(accessory)
      }
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
    rebuild()
  }
}

#if DEBUG
extension HomeStore
{
  /// Sample data for previews and `-demo` launches. Never touches HomeKit.
  static func demo() -> HomeStore
  {
    let store = HomeStore()
    store.isDemo = true
    store.devices = SampleData.devices
    store.homeCount = 1
    store.lastRefresh = .now
    store.phase = .ready
    return store
  }
}
#endif
