import SwiftUI

struct DashboardView: View
{
  @Environment(HomeStore.self) private var store
  @Environment(WebDashboard.self) private var web
  @Environment(\.scenePhase) private var scenePhase
  @State private var grouping = Grouping.room
  /// False within a minute of the last refresh, when the store won't refresh again yet.
  @State private var canRefresh = true

  var body: some View
  {
    NavigationStack
    {
      content
        .navigationTitle("Home Sensors")
        .toolbar
        {
          ToolbarItem(placement: .primaryAction)
          {
            refreshControl
          }
        }
    }
    .onChange(of: scenePhase)
    {
      if scenePhase == .active
      {
        store.refreshIfStale()
      }
    }
    .task(id: store.lastRefresh)
    {
      await holdRefreshButton()
    }
  }

  @ViewBuilder
  private var content: some View
  {
    switch store.phase
    {
    case .loading:
      ProgressView("Loading Home data…")
    case .notAuthorized:
      ContentUnavailableView(
        "No access to Home data",
        systemImage: "house.slash",
        description: Text("Allow Home Sensors under Privacy & Security › HomeKit in Settings.")
      )
    case .noHomes:
      ContentUnavailableView(
        "No homes",
        systemImage: "house",
        description: Text("Set up a home in the Home app first.")
      )
    case .ready:
      if store.devices.isEmpty
      {
        ContentUnavailableView(
          "No sensors found",
          systemImage: "sensor",
          description: Text("No accessory reports a battery level or a sensor reading.")
        )
      }
      else
      {
        dashboard
      }
    }
  }

  private var dashboard: some View
  {
    ScrollView
    {
      VStack(alignment: .leading, spacing: 24)
      {
        SummaryTiles(summary: Summary(devices: store.devices))
        controls
        ForEach(DeviceSection.make(from: store.devices, grouping: grouping, showHome: store.homeCount > 1))
        {
          section in
          SectionCard(section: section, showRoom: grouping == .battery)
        }
      }
      .padding(20)
      .frame(maxWidth: 1100)
      .frame(maxWidth: .infinity)
    }
    .background(Color(.systemGroupedBackground))
  }

  private var controls: some View
  {
    HStack(spacing: 12)
    {
      Picker("Group by", selection: $grouping)
      {
        ForEach(Grouping.allCases)
        {
          option in
          Text(option.rawValue)
            .tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      Spacer()
      VStack(alignment: .trailing, spacing: 2)
      {
        updatedLabel
        webLabel
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var webLabel: some View
  {
    if let address = web.address, let url = URL(string: address)
    {
      Link("Web: \(address)", destination: url)
        .buttonStyle(.borderless)
        .help("Phones on the same network can open this address.")
    }
    else if let failure = web.failure
    {
      Text(failure)
    }
  }

  @ViewBuilder
  private var updatedLabel: some View
  {
    if store.isRefreshing
    {
      Text("Updating…")
    }
    else if let lastRefresh = store.lastRefresh
    {
      Text("Updated \(lastRefresh, format: .dateTime.hour().minute())")
    }
  }

  @ViewBuilder
  private var refreshControl: some View
  {
    if store.isRefreshing
    {
      ProgressView()
        .controlSize(.small)
    }
    else
    {
      Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
        .keyboardShortcut("r")
        .disabled(store.phase != .ready || !canRefresh)
        .help(canRefresh ? "Refresh readings" : "Refreshed less than a minute ago")
    }
  }

  private func refresh()
  {
    store.refreshIfStale()
  }

  /// Keeps the Refresh button off until the store can refresh again.
  private func holdRefreshButton() async
  {
    let wait = RefreshLimit.wait(after: store.lastRefresh)
    canRefresh = wait == 0
    if wait == 0
    {
      return
    }
    do
    {
      try await Task.sleep(for: .seconds(wait))
      canRefresh = true
    }
    catch
    {
      // A newer refresh restarted the wait.
    }
  }
}

struct SummaryTiles: View
{
  var summary: Summary

  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View
  {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .compact ? 2 : 4)
    LazyVGrid(columns: columns, spacing: 12)
    {
      ForEach(summary.tiles, id: \.label)
      {
        tile in
        StatTile(label: tile.label, value: tile.value, detail: tile.detail, status: tile.status)
      }
    }
  }
}

struct SectionCard: View
{
  var section: DeviceSection
  var showRoom: Bool

  var body: some View
  {
    VStack(alignment: .leading, spacing: 8)
    {
      Text(section.title)
        .font(.headline)
        .padding(.leading, 4)
      VStack(spacing: 0)
      {
        ForEach(section.devices)
        {
          device in
          DeviceRow(device: device, showRoom: showRoom)
            .overlay(alignment: .top)
            {
              if device.id != section.devices.first?.id
              {
                Divider()
                  .padding(.leading, 48)
              }
            }
        }
      }
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

#if DEBUG
#Preview
{
  let store = HomeStore.demo()
  DashboardView()
    .environment(store)
    .environment(WebDashboard(store: store))
}
#endif
