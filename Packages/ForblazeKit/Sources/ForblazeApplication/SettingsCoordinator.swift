import ForblazeCore
public struct AppSettings: Codable, Equatable, Sendable {
    public var binding: TriggerBinding
    public var farField: Bool
    public var sounds: Bool
    public var muteOutputDuringDictation:Bool
    public var punctuationCorrection:Bool
    public var forblazeMode:Bool
    public var copyToClipboard:Bool
    public var prewarmRecognition:Bool
    public var speechBufferSize:SpeechBufferSize
    public var balancedInput:Bool
    public init(binding: TriggerBinding = .defaultBinding, farField: Bool = true, sounds: Bool = true,punctuationCorrection:Bool=false,forblazeMode:Bool=false,copyToClipboard:Bool=false,prewarmRecognition:Bool=false,speechBufferSize:SpeechBufferSize = .standard,balancedInput:Bool=false,muteOutputDuringDictation:Bool=false) {
        self.binding = binding; self.farField = farField; self.sounds = sounds;self.punctuationCorrection=punctuationCorrection;self.forblazeMode=forblazeMode
        self.copyToClipboard=copyToClipboard
        self.prewarmRecognition=prewarmRecognition;self.speechBufferSize=speechBufferSize;self.balancedInput=balancedInput
        self.muteOutputDuringDictation=muteOutputDuringDictation
    }
    private enum CodingKeys:String,CodingKey {case binding,farField,sounds,punctuationCorrection,forblazeMode,copyToClipboard,prewarmRecognition,speechBufferSize,balancedInput,muteOutputDuringDictation}
    public init(from decoder:any Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        binding=try values.decode(TriggerBinding.self,forKey:.binding)
        farField=try values.decode(Bool.self,forKey:.farField)
        sounds=try values.decode(Bool.self,forKey:.sounds)
        muteOutputDuringDictation=try values.decodeIfPresent(Bool.self,forKey:.muteOutputDuringDictation) ?? false
        punctuationCorrection=try values.decodeIfPresent(Bool.self,forKey:.punctuationCorrection) ?? false
        forblazeMode=try values.decodeIfPresent(Bool.self,forKey:.forblazeMode) ?? false
        copyToClipboard=try values.decodeIfPresent(Bool.self,forKey:.copyToClipboard) ?? false
        prewarmRecognition=try values.decodeIfPresent(Bool.self,forKey:.prewarmRecognition) ?? false
        speechBufferSize=try values.decodeIfPresent(SpeechBufferSize.self,forKey:.speechBufferSize) ?? .standard
        balancedInput=try values.decodeIfPresent(Bool.self,forKey:.balancedInput) ?? false
    }
    public var isValid: Bool { binding.isValid }
}
public enum SettingsOption: Sendable { case farField, sounds, punctuationCorrection, forblazeMode, copyToClipboard,prewarmRecognition,balancedInput,muteOutputDuringDictation }
public enum StoredSettings: Equatable, Sendable { case missing, valid(AppSettings), invalid }
@MainActor public protocol SettingsStore: AnyObject {
    func load() throws -> StoredSettings
    func replace(_ value: StoredSettings) throws
}
@MainActor public protocol TriggerService: AnyObject {
    var keysReleased: Bool { get }
    var onToggle: ((BindingRevision) -> Void)? { get set }
    var onKeyInput: ((KeyInput) -> Void)? { get set }
    var onManualInput: (() -> Void)? {get set}
    func start() throws
    func stop()
    func setEnabled(_ enabled: Bool)
    func apply(_ binding: TriggerBinding?, revision: BindingRevision) throws
    func resetKeys()
}
public enum SettingsFailure: Error, Equatable, Sendable {
    case sessionActive, invalidCandidate, keyHeld, apply, save, restore, corrupt
}
@MainActor public final class SettingsCoordinator {
    public private(set) var saved: StoredSettings
    public private(set) var revision = BindingRevision(1)
    public private(set) var candidate: TriggerBinding?
    public private(set) var capturing = false
    public private(set) var error: SettingsFailure?
    public var onChange: (() -> Void)?
    private var requiresRecovery=false
    private var resumeOnRelease=false
    private var candidateLocked=false
    public var keysReleased:Bool {trigger.keysReleased}
    private let trigger: any TriggerService
    private let store: any SettingsStore
    public var current: AppSettings? {
        switch saved { case .missing: AppSettings(); case .valid(let value): value; case .invalid: nil }
    }
    public init(trigger: any TriggerService, store: any SettingsStore) {
        self.trigger=trigger;self.store=store
        saved=(try? store.load()) ?? .invalid
    }
    public func restoreAtStartup() {
        trigger.setEnabled(false)
        guard !requiresRecovery else {error = .restore;onChange?();return}
        guard let current, current.isValid else { error = .corrupt; onChange?(); return }
        do { try trigger.apply(current.binding, revision: revision); trigger.setEnabled(trigger.keysReleased) }
        catch { self.error = .apply }
        onChange?()
    }
    public func beginCapture(isIdle:Bool) {
        guard isIdle else { error = .sessionActive; onChange?(); return }
        trigger.setEnabled(false); capturing = true; resumeOnRelease=false; candidate = nil; candidateLocked=false; error = nil; onChange?()
    }
    public func receive(_ input:KeyInput) {
        if input.kind == .up {
            if capturing,candidate != nil,trigger.keysReleased {candidateLocked=true}
            if resumeOnRelease, trigger.keysReleased, !requiresRecovery {
                trigger.setEnabled(current != nil); resumeOnRelease=false
            }
            onChange?(); return
        }
        guard capturing, !input.isRepeat else { return }
        if candidateLocked {onChange?();return}
        let value = TriggerBinding(keyCode: input.code, modifiers: input.modifiers)
        candidate = value.isValid ? value : nil
        error = value.isValid ? nil : .invalidCandidate; onChange?()
    }
    public func cancel() {
        candidate = nil; candidateLocked=false; capturing = false; resumeOnRelease = !trigger.keysReleased
        if requiresRecovery {error = .restore;trigger.setEnabled(false)}
        else {error = nil;trigger.setEnabled(current != nil && trigger.keysReleased)}
        onChange?()
    }
    public func useDefault(isIdle:Bool) {
        beginCapture(isIdle: isIdle)
        if capturing { candidate = .defaultBinding; candidateLocked=true; onChange?() }
    }
    /// スイッチの保存ではキー候補・監視状態・割り当ての世代を変更しない。
    public func setOption(_ option:SettingsOption,enabled:Bool,isIdle:Bool) {
        guard !requiresRecovery else {error = .restore;onChange?();return}
        guard isIdle else {error = .sessionActive;onChange?();return}
        guard var next=current,next.isValid else {error = .corrupt;onChange?();return}
        switch option {
        case .farField:next.farField=enabled
        case .sounds:next.sounds=enabled
        case .muteOutputDuringDictation:next.muteOutputDuringDictation=enabled
        case .punctuationCorrection:next.punctuationCorrection=enabled
        case .forblazeMode:next.forblazeMode=enabled
        case .copyToClipboard:next.copyToClipboard=enabled
        case .prewarmRecognition:next.prewarmRecognition=enabled
        case .balancedInput:next.balancedInput=enabled
        }
        persist(next)
    }
    public func setBufferSize(_ size:SpeechBufferSize,isIdle:Bool) {
        guard !requiresRecovery else {error = .restore;onChange?();return}
        guard isIdle else {error = .sessionActive;onChange?();return}
        guard var next=current,next.isValid else {error = .corrupt;onChange?();return}
        next.speechBufferSize=size
        persist(next)
    }
    private func persist(_ next:AppSettings) {
        guard next != current else {return}
        let previous=saved
        do {
            try store.replace(.valid(next))
            saved = .valid(next)
            // スイッチの保存成功で、別のキー操作の失敗を解消した表示にしない。
            if error != .apply && error != .invalidCandidate && error != .keyHeld {error=nil}
        } catch {
            self.error = .save
            do {try store.replace(previous)}
            catch {self.error = .restore;requiresRecovery=true;trigger.setEnabled(false)}
        }
        onChange?()
    }
    public func save(isIdle:Bool,farField:Bool=true,sounds:Bool=true,punctuationCorrection:Bool?=nil,forblazeMode:Bool?=nil) {
        guard isIdle else { error = .sessionActive; onChange?(); return }
        guard trigger.keysReleased else { error = .keyHeld; onChange?(); return }
        guard let candidate = candidate ?? (!capturing ? current?.binding : nil), candidate.isValid else { error = .invalidCandidate; onChange?(); return }
        trigger.setEnabled(false)
        let previous = saved, previousBinding = current?.binding
        let nextRevision = BindingRevision(revision.value + 1)
        var next=current ?? AppSettings()
        next.binding=candidate;next.farField=farField;next.sounds=sounds
        if let punctuationCorrection {next.punctuationCorrection=punctuationCorrection}
        if let forblazeMode {next.forblazeMode=forblazeMode}
        var failure = SettingsFailure.apply
        do {
            try trigger.apply(candidate, revision: nextRevision)
            failure = .save
            try store.replace(.valid(next))
            saved = .valid(next); revision = nextRevision; self.candidate = nil
            capturing = false; candidateLocked=false; requiresRecovery=false; error = nil; trigger.setEnabled(true)
        } catch {
            self.error = failure
            do {
                try trigger.apply(previousBinding, revision: revision)
                try store.replace(previous)
                requiresRecovery=false
                trigger.setEnabled(previousBinding != nil && trigger.keysReleased)
            } catch { self.error = .restore; requiresRecovery=true; trigger.setEnabled(false) }
        }
        onChange?()
    }
}

public extension TriggerService {
    var onManualInput:(()->Void)? {get {nil} set {}}
}
