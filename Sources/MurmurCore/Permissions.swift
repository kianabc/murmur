import AVFoundation
import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// The three permissions Murmur needs, each behind a different macOS gate.
/// This is where users bounce — see SPEC.md §9.
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// Plain explanation of *why*. Users grant permissions they understand.
    public var rationale: String {
        switch self {
        case .microphone:
            "To hear you. Audio is processed on this Mac and never uploaded."
        case .accessibility:
            "To type text at your cursor and find where that cursor is."
        case .inputMonitoring:
            "To notice your hotkey while you're in another app."
        }
    }

    /// Deep link to the exact System Settings pane.
    public var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone: return URL(string: base + "Privacy_Microphone")
        case .accessibility: return URL(string: base + "Privacy_Accessibility")
        case .inputMonitoring: return URL(string: base + "Privacy_ListenEvent")
        }
    }
}

public enum PermissionState: Sendable {
    case granted
    case denied
    /// Never asked, or macOS won't say. Treated as "needs action" in onboarding.
    case undetermined
}

public struct Permissions {
    public init() {}

    public func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }

        case .accessibility:
            // Passive check — does NOT show the system prompt.
            return AXIsProcessTrusted() ? .granted : .denied

        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .undetermined
            }
        }
    }

    public var allGranted: Bool {
        Permission.allCases.allSatisfy { state(of: $0) == .granted }
    }

    /// Ask for a permission. Microphone and Input Monitoring can show a real
    /// prompt; Accessibility can only be toggled by hand, so we prompt once and
    /// then rely on the user visiting Settings.
    public func request(_ permission: Permission, completion: @escaping (Bool) -> Void) {
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }

        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let granted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            completion(granted)

        case .inputMonitoring:
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            completion(granted)
        }
    }

    public func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// True when macOS has enabled secure input — a password field is focused
    /// somewhere and our event tap has gone deaf. Detect it and say so, rather
    /// than appearing broken. See SPEC.md §3.5.
    public static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }
}
