import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register for remote control events so lock screen / Control Center
    // media controls appear. The audio_service plugin activates
    // MPRemoteCommandCenter but doesn't call this, which can prevent
    // Now Playing from appearing on scene-based lifecycle apps.
    application.beginReceivingRemoteControlEvents()

    // Pre-configure audio session for playback so iOS knows this app
    // plays audio before the Flutter engine finishes initializing.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    } catch {
      print("[AppDelegate] Audio session setup failed: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.absorb.audio_output",
                                       binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "getAudioOutputDevices":
        result(self?.getAudioOutputDevices() ?? [])
      case "setAudioOutputDevice":
        if let args = call.arguments as? [String: Any], let id = args["id"] as? Int {
          result(self?.setAudioOutputDevice(portIndex: id) ?? false)
        } else {
          result(false)
        }
      case "resetAudioOutput":
        result(self?.resetAudioOutput() ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let storageChannel = FlutterMethodChannel(name: "com.absorb.storage",
                                              binaryMessenger: controller.binaryMessenger)
    storageChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getDeviceStorage":
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
          result(["totalBytes": total, "availableBytes": free])
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eqChannel = FlutterMethodChannel(name: "com.absorb.equalizer",
                                          binaryMessenger: controller.binaryMessenger)
    eqChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "isBluetoothAudioConnected":
        result(self?.isBluetoothAudioConnected() ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func isBluetoothAudioConnected() -> Bool {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    return outputs.contains { port in
      port.portType == .bluetoothA2DP ||
      port.portType == .bluetoothHFP ||
      port.portType == .bluetoothLE
    }
  }

  private func getAudioOutputDevices() -> [[String: Any]] {
    let session = AVAudioSession.sharedInstance()
    let currentOutputs = session.currentRoute.outputs
    let currentPortUIDs = Set(currentOutputs.map { $0.uid })

    var devices: [[String: Any]] = []
    var seenTypes = Set<String>()

    // Add current outputs first
    for port in currentOutputs {
      let typeName = portTypeName(port.portType)
      seenTypes.insert(typeName)
      devices.append([
        "id": port.uid.hashValue,
        "name": port.portName,
        "typeName": typeName,
        "isActive": true,
        "uid": port.uid,
      ])
    }

    // Add available outputs that aren't current
    for output in session.availableInputs ?? [] {
      // availableInputs on iOS - for Bluetooth HFP, the input port maps to output too
    }

    // Always add speaker if not already current
    if !seenTypes.contains("speaker") {
      devices.append([
        "id": "speaker".hashValue,
        "name": "This iPhone",
        "typeName": "speaker",
        "isActive": false,
        "uid": "speaker",
      ])
    }

    return devices
  }

  private func portTypeName(_ portType: AVAudioSession.Port) -> String {
    switch portType {
    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
      return "bluetooth"
    case .headphones:
      return "wired"
    case .builtInSpeaker:
      return "speaker"
    case .builtInReceiver:
      return "earpiece"
    case .usbAudio:
      return "usb"
    default:
      return "unknown"
    }
  }

  private func setAudioOutputDevice(portIndex: Int) -> Bool {
    let session = AVAudioSession.sharedInstance()
    // If requesting speaker, override to speaker
    if portIndex == "speaker".hashValue {
      do {
        try session.overrideOutputAudioPort(.speaker)
        return true
      } catch { return false }
    }
    // Otherwise, clear override to let system route to connected device
    do {
      try session.overrideOutputAudioPort(.none)
      return true
    } catch { return false }
  }

  private func resetAudioOutput() -> Bool {
    do {
      try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
      return true
    } catch { return false }
  }
}
