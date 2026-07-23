import Carbon
import Foundation

final class GlobalHotKeyManager {
  enum RegistrationResult: Equatable {
    case success
    case failure(OSStatus)
  }

  var onPressed: (() -> Void)?

  private let signature: OSType = 0x5749_4E4F  // "WINO"
  private let identifier: UInt32 = 1
  private var eventHandlerRef: EventHandlerRef?
  private var hotKeyRef: EventHotKeyRef?

  deinit {
    unregister()
  }

  func registerDefault() -> RegistrationResult {
    register(
      keyCode: UInt32(kVK_Space),
      modifiers: UInt32(controlKey)
    )
  }

  func register(keyCode: UInt32, modifiers: UInt32) -> RegistrationResult {
    unregisterHotKey()
    installEventHandlerIfNeeded()

    let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )

    return status == noErr ? .success : .failure(status)
  }

  func unregister() {
    unregisterHotKey()

    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else {
      return
    }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let callback: EventHandlerUPP = { _, event, userData in
      guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
      }

      let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
      var hotKeyID = EventHotKeyID()
      let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )

      guard
        status == noErr,
        hotKeyID.signature == manager.signature,
        hotKeyID.id == manager.identifier
      else {
        return OSStatus(eventNotHandledErr)
      }

      DispatchQueue.main.async {
        manager.onPressed?()
      }
      return noErr
    }

    InstallEventHandler(
      GetApplicationEventTarget(),
      callback,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )
  }

  private func unregisterHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
  }
}
