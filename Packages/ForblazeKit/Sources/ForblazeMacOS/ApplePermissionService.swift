import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import Speech
import ForblazeApplication
@MainActor public final class ApplePermissionService: PermissionService {
    public var eventTap: EventTapStatus = .unknown
    private let inputMonitoringAccess: () -> Bool
    private let requestInputMonitoringAccess: () -> Bool
    private let openSettings: (URL) -> Bool
    public convenience init() {
        self.init(inputMonitoringAccess: {CGPreflightListenEventAccess()},
                  requestInputMonitoringAccess: {CGRequestListenEventAccess()},
                  openSettings: {NSWorkspace.shared.open($0)})
    }
    init(inputMonitoringAccess: @escaping () -> Bool,
         requestInputMonitoringAccess: @escaping () -> Bool,
         openSettings: @escaping (URL) -> Bool) {
        self.inputMonitoringAccess=inputMonitoringAccess
        self.requestInputMonitoringAccess=requestInputMonitoringAccess
        self.openSettings=openSettings
    }
    public func snapshot() async -> Availability {
        let microphone: PermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .unknown
        case .restricted: microphone = .restricted
        case .denied: microphone = .denied
        @unknown default: microphone = .unknown
        }
        let speech: PermissionStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .granted
        case .notDetermined: speech = .unknown
        case .restricted: speech = .restricted
        case .denied: speech = .denied
        @unknown default: speech = .unknown
        }
        let module = Self.module(farField: true)
        let model: ModelStatus
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: model = .unsupported
        case .supported: model = .missing
        case .downloading: model = .downloading
        case .installed: model = .installed
        @unknown default: model = .unknown
        }
        return Availability(permissions: [
            .inputMonitoring: inputMonitoringAccess() ? .granted : .denied,
            .accessibility: AXIsProcessTrusted() ? .granted : .denied,
            .microphone: microphone, .speech: speech
        ], model: model, eventTap: eventTap)
    }
    public func request(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .inputMonitoring:
            let granted=inputMonitoringAccess() || requestInputMonitoringAccess()
            // 拒否済みや更新後は許可ダイアログが出ない場合も、手動で確認できるようにする。
            _=openSettings(URL(string:"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!)
            return granted
        case .accessibility:
            return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .microphone: return await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
    static func module(farField: Bool) -> DictationTranscriber {
        DictationTranscriber(locale:Locale(identifier:"ja-JP"),preset:preset(farField:farField))
    }
    static func preset(farField:Bool)->DictationTranscriber.Preset {
        // 途中結果は即時に受け取り、精度を下げる早期確定は要求しない。
        .init(contentHints:farField ? [.farField] : [],transcriptionOptions:[.punctuation],
              reportingOptions:[.volatileResults],attributeOptions:[.audioTimeRange])
    }
}
