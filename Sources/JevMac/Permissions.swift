import ApplicationServices
import AVFoundation
import Foundation
import Speech

public enum PermissionState: String, Sendable {
    case authorized, denied, restricted, notDetermined, unknown
}

/// The three grants the app needs: Microphone, Speech Recognition, Accessibility. Screen
/// Recording is not requested in v1 (no screenshots, no OCR).
public enum Permissions {
    public static func microphone() -> PermissionState {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public static func requestMicrophone() async -> PermissionState {
        if microphone() == .authorized { return .authorized }
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        return ok ? .authorized : microphone()
    }

    public static func speech() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    public static func requestSpeech() async -> PermissionState {
        if speech() == .authorized { return .authorized }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume(returning: speech()) }
        }
    }

    /// Accessibility trust for this process (AX reads and synthetic input). With `prompt`,
    /// macOS shows the System Settings prompt once.
    public static func accessibility(prompt: Bool = false) -> PermissionState {
        if prompt {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary   // kAXTrustedCheckOptionPrompt
            return AXIsProcessTrustedWithOptions(opts) ? .authorized : .denied
        }
        return AXIsProcessTrusted() ? .authorized : .denied
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }
}
