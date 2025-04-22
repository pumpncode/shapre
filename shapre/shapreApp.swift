import SwiftUI

@main
struct shapreApp: App {
  init() {
    OverlayWindowController.shared.show()
  }
  var body: some Scene {
    WindowGroup {
      EmptyView()
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .commands {
      CommandGroup(replacing: .appInfo) {}
    }
  }
}
