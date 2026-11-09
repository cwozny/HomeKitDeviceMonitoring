import SwiftUI
import UIKit

/// The app's window. The dashboard itself is the web page, so the window shows only the page's address,
/// when data last arrived, and HomeKit problems.
struct StatusView: View
{
  @Environment(HomeStore.self) private var store
  @Environment(WebDashboard.self) private var web

  var body: some View
  {
    VStack(spacing: 16)
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
        // Always with the date: the text changes only when data arrives, also on a later day.
        if let lastUpdate = store.lastUpdate
        {
          Text("Updated \(lastUpdate, format: .dateTime.month().day().hour().minute())")
        }
      }
      webLabel
    }
    .padding(20)
    #if targetEnvironment(macCatalyst)
    .background(WindowLock())
    #endif
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
}

#if targetEnvironment(macCatalyst)
/// Turns off the window's minimize and close buttons. Either one makes the app not visible, and HomeKit
/// sends no changes to an app that isn't visible.
private struct WindowLock: UIViewRepresentable
{
  func makeUIView(context: Context) -> LockingView
  {
    LockingView()
  }

  func updateUIView(_ uiView: LockingView, context: Context)
  {
  }

  final class LockingView: UIView
  {
    override func didMoveToWindow()
    {
      super.didMoveToWindow()
      if let behaviors = window?.windowScene?.windowingBehaviors
      {
        behaviors.isMiniaturizable = false
        behaviors.isClosable = false
      }
    }
  }
}
#endif
