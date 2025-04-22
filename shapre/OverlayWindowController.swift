import AppKit
import Carbon
import SwiftUI

final class OverlayWindowController: NSObject {
  static let shared = OverlayWindowController()
  static var overlayWindowID: CGWindowID?
  static var isActive = false

  private var window: NSWindow?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var capturedScreenView: CapturedScreenMetalView?

  deinit {
    cleanup()
  }

  func show() {
    guard window == nil else { return }
    OverlayWindowController.isActive = true

    let screen = NSScreen.main!

    let window = NSWindow(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.isReleasedWhenClosed = false
    window.level = .screenSaver
    window.ignoresMouseEvents = true
    window.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]

    if let number = window.windowNumber as Int?, number > 0 {
      OverlayWindowController.overlayWindowID = CGWindowID(number)
    }

    window.contentView = NSHostingView(
      rootView:
        ZStack {
          CapturedScreenMetalView() as CapturedScreenMetalView
          Color.clear.contentShape(Rectangle())
        }
    )
    window.makeKeyAndOrderFront(nil)

    registerGlobalHotkey()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )

    self.window = window
  }

  func cleanup() {

    if let eventTap = eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      self.eventTap = nil
    }

    if let runLoopSource = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }

    window?.close()
    window = nil

    NotificationCenter.default.removeObserver(self)

    OverlayWindowController.overlayWindowID = nil
  }

  @objc func applicationWillTerminate(_ notification: Notification) {
    cleanup()
  }

  func registerGlobalHotkey() {
    let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)

            switch keycode {
            case 53:
              DispatchQueue.main.async {
                OverlayWindowController.shared.cleanup()
                NSApp.terminate(nil)
              }
              return nil

            case 47:
              DispatchQueue.main.async {
                OverlayWindowController.shared.toggleOverlay()
              }
              return nil

            default:
              break
            }
          }
          return Unmanaged.passRetained(event)
        },
        userInfo: nil
      )
    else {
      print("Failed to create event tap")
      return
    }

    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

    CGEvent.tapEnable(tap: eventTap, enable: true)

    self.eventTap = eventTap
    self.runLoopSource = runLoopSource
  }

  func toggleOverlay() {
    if OverlayWindowController.isActive {
      hide()
    } else {
      show()
    }
  }

  func hide() {
    guard OverlayWindowController.isActive else { return }

    let currentWindow = window

    window = nil

    DispatchQueue.main.async {
      currentWindow?.close()

      OverlayWindowController.isActive = false
      OverlayWindowController.overlayWindowID = nil
    }
  }
}
