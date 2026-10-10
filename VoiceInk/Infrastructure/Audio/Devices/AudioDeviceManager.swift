import AppKit
import AVFoundation
import CoreAudio
import Foundation
import IOKit.audio
import os

struct PrioritizedDevice: Codable, Identifiable {
    let id: String
    let name: String
    var priority: Int
    var modelUID: String?
    var requirements: MicrophoneRequirements?
}

enum AudioInputMode: String, CaseIterable {
    case systemDefault = "System Default"
    case custom = "Custom Device"
    case prioritized = "Prioritized"
}

class AudioDeviceManager: ObservableObject {
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioDeviceManager")
    let userDefaults: UserDefaults
    let notificationCenter: NotificationCenter
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var defaultInputChangeListener: AudioObjectPropertyListenerBlock?
    @Published var availableDevices: [(id: AudioDeviceID, uid: String, name: String)] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var inputMode: AudioInputMode = .custom
    @Published var prioritizedDevices: [PrioritizedDevice] = []
    @Published private(set) var temporaryMicrophone: MicrophoneReference?
    @Published private(set) var runningApplicationBundleIDs = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var eligiblePreferredMicrophones = Set<String>()

    var recordingDeviceSession = RecordingDeviceSession()
    var clamshellStateMonitor: ClamshellStateMonitor?

    var isRecordingActive: Bool { recordingDeviceSession.isActive }
    var activeRecordingDeviceID: AudioDeviceID? { recordingDeviceSession.activeDeviceID }
    var isClamshellClosed: Bool { clamshellStateMonitor?.isClosed == true }

    static let shared = AudioDeviceManager()

    init(userDefaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        loadPrioritizedDevices()

        if let savedMode = userDefaults.audioInputModeRawValue,
            let mode = AudioInputMode(rawValue: savedMode)
        {
            inputMode = mode
        } else {
            inputMode = .systemDefault
        }

        startMonitoring()

        loadAvailableDevices { [weak self] in
            self?.initializeSelectedDevice()
        }
    }

    func startMonitoring() {
        setupRecordingDeviceRouting()
        setupDeviceChangeNotifications()
        setupApplicationMonitoring()
    }

    func getSystemDefaultDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            logger.error("Failed to get system default device: \(status, privacy: .public)")
            return nil
        }
        return deviceID
    }

    func getSystemDefaultDeviceName() -> String? {
        guard let deviceID = getSystemDefaultDevice() else { return nil }
        return getDeviceName(deviceID: deviceID)
    }

    private func initializeSelectedDevice() {
        reconcileInputAvailability()
    }

    private func fallbackToDefaultDevice() {
        guard let newDeviceID = findBestAvailableDevice() else {
            logger.error("No input devices available!")
            selectedDeviceID = nil
            notifyDeviceChange()
            return
        }
        activateDevice(id: newDeviceID)
    }

    private func activateDevice(id: AudioDeviceID) {
        selectedDeviceID = id
        notifyDeviceChange()
    }

    func loadAvailableDevices(completion: (() -> Void)? = nil) {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        if result != noErr {
            logger.error("Error getting audio devices: \(result, privacy: .public)")
            return
        }

        let devices = deviceIDs.compactMap { deviceID -> (id: AudioDeviceID, uid: String, name: String)? in
            guard let name = getDeviceName(deviceID: deviceID),
                let uid = getDeviceUID(deviceID: deviceID),
                isValidInputDevice(deviceID: deviceID)
            else {
                return nil
            }
            return (id: deviceID, uid: uid, name: name)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.availableDevices = devices.map { ($0.id, $0.uid, $0.name) }
            self.reconcileInputAvailability()
            completion?()
        }
    }

    func getDeviceName(deviceID: AudioDeviceID) -> String? {
        let name = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString)
        return name as String?
    }

    func isValidInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        )

        if result != noErr {
            logger.error(
                "Error checking input capability for device \(deviceID, privacy: .public): \(result, privacy: .public)")
            return false
        }

        let bufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListStorage.deallocate() }
        let bufferList = bufferListStorage.assumingMemoryBound(to: AudioBufferList.self)

        result = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            bufferList
        )

        if result != noErr {
            logger.error(
                "Error getting stream configuration for device \(deviceID, privacy: .public): \(result, privacy: .public)"
            )
            return false
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).contains {
            $0.mNumberChannels > 0
        }
    }

    func selectDevice(id: AudioDeviceID) {
        if let deviceToSelect = availableDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.temporaryMicrophone = nil
                self.selectedDeviceID = id
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectDeviceAndSwitchToCustomMode(id: AudioDeviceID) {
        if let deviceToSelect = availableDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.temporaryMicrophone = nil
                self.inputMode = .custom
                self.selectedDeviceID = id
                self.userDefaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectInputMode(_ mode: AudioInputMode) {
        temporaryMicrophone = nil
        inputMode = mode
        userDefaults.audioInputModeRawValue = mode.rawValue

        reconcileInputAvailability()
    }

    private func loadPrioritizedDevices() {
        if let data = userDefaults.prioritizedDevicesData,
            let devices = try? JSONDecoder().decode([PrioritizedDevice].self, from: data)
        {
            prioritizedDevices = devices
        }
    }

    func savePrioritizedDevices() {
        if let data = try? JSONEncoder().encode(prioritizedDevices) {
            userDefaults.prioritizedDevicesData = data
        }
    }

    func addPrioritizedDevice(uid: String, name: String) {
        guard !prioritizedDevices.contains(where: { $0.id == uid }) else { return }
        let modelUID = availableDevices.first(where: { $0.uid == uid })
            .flatMap { getDeviceModelUID(deviceID: $0.id) }
        let nextPriority = (prioritizedDevices.map { $0.priority }.max() ?? -1) + 1
        let device = PrioritizedDevice(id: uid, name: name, priority: nextPriority, modelUID: modelUID)
        prioritizedDevices.append(device)
        savePrioritizedDevices()
        reconcileInputAvailability()
    }

    func removePrioritizedDevice(id: String) {
        prioritizedDevices.removeAll { $0.id == id }

        let updatedDevices = prioritizedDevices.enumerated().map { index, device in
            var updated = device
            updated.priority = index
            return updated
        }

        prioritizedDevices = updatedDevices
        savePrioritizedDevices()

        reconcileInputAvailability()
    }

    func updatePriorities(devices: [PrioritizedDevice]) {
        temporaryMicrophone = nil
        prioritizedDevices = devices
        savePrioritizedDevices()

        reconcileInputAvailability()
    }

    func selectTemporaryMicrophone(id: AudioDeviceID) {
        guard let device = availableDevices.first(where: { $0.id == id }),
            isDeviceUsableForRecording(id)
        else { return }

        temporaryMicrophone = MicrophoneReference(
            uid: device.uid, name: device.name, modelUID: getDeviceModelUID(deviceID: id)
        )
        eligiblePreferredMicrophones = eligibleAutomaticMicrophones()
        reconcileInputAvailability()
    }

    func resumeAutomaticMicrophoneSelection() {
        temporaryMicrophone = nil
        reconcileInputAvailability()
    }

    func updateMicrophoneRequirements(_ requirements: MicrophoneRequirements, for uid: String) {
        guard let index = prioritizedDevices.firstIndex(where: { $0.id == uid }) else { return }
        prioritizedDevices[index].requirements = requirements.isEmpty ? nil : requirements
        savePrioritizedDevices()
        reconcileInputAvailability()
    }

    func unmetMicrophoneRequirements(for device: PrioritizedDevice) -> [String] {
        guard let requirements = device.requirements else { return [] }
        var unmet: [String] = []
        if let microphone = requirements.microphone {
            let source = findAvailableDevice(uid: microphone.uid, modelUID: microphone.modelUID)
            if source.map({ isPhysicalInputUsable($0.id) }) != true {
                unmet.append(String(localized: "Requires microphone: \(microphone.name)"))
            }
        }
        if let application = requirements.application,
            !runningApplicationBundleIDs.contains(application.bundleID)
        {
            unmet.append(String(localized: "Requires open application: \(application.name)"))
        }
        return unmet
    }

    func microphoneRequirementsAreMet(for deviceID: AudioDeviceID) -> Bool {
        guard let saved = prioritizedDevices.first(where: {
            findAvailableDevice(uid: $0.id, modelUID: $0.modelUID)?.id == deviceID
        }) else { return true }
        return unmetMicrophoneRequirements(for: saved).isEmpty
    }

    func reconcileInputAvailability(reason: RecordingDeviceChangeReason = .deviceUnavailable) {
        let eligible = eligibleAutomaticMicrophones()
        if let temporary = temporaryMicrophone {
            let selected = findAvailableDevice(uid: temporary.uid, modelUID: temporary.modelUID)
            let automaticDevices = automaticRecordingDeviceIDs()
            let temporaryIndex = selected.flatMap { automaticDevices.firstIndex(of: $0.id) }
                ?? automaticDevices.endIndex
            let newlyEligible = eligible.subtracting(eligiblePreferredMicrophones)
            let preferredReturned = automaticDevices.prefix(temporaryIndex).contains { id in
                availableDevices.first(where: { $0.id == id }).map { newlyEligible.contains($0.uid) } == true
            }
            if selected.map({ isDeviceUsableForRecording($0.id) }) != true || preferredReturned {
                temporaryMicrophone = nil
            }
        }
        eligiblePreferredMicrophones = eligible

        if isRecordingActive {
            if let activeRecordingDeviceID, !isDeviceUsableForRecording(activeRecordingDeviceID) {
                requestRecordingDeviceChange(reason: reason)
            }
            notifyDeviceChange()
            return
        }

        selectedDeviceID = resolveCurrentRecordingDevice().deviceID
        refreshSavedMicrophoneReferences()
        notifyDeviceChange()
    }

    func updateRunningApplications(_ bundleIDs: Set<String>) {
        guard runningApplicationBundleIDs != bundleIDs else { return }
        runningApplicationBundleIDs = bundleIDs
        reconcileInputAvailability()
    }

    private func eligibleAutomaticMicrophones() -> Set<String> {
        Set(automaticRecordingDeviceIDs().filter(isDeviceUsableForRecording).compactMap { id in
            availableDevices.first(where: { $0.id == id })?.uid
        })
    }

    private func refreshSavedMicrophoneReferences() {
        if inputMode == .custom,
            let savedUID = userDefaults.selectedAudioDeviceUID,
            let found = findAvailableDevice(uid: savedUID, modelUID: userDefaults.selectedAudioDeviceModelUID),
            found.uid != savedUID || userDefaults.selectedAudioDeviceModelUID == nil
        {
            updateCustomDeviceHints(deviceID: found.id, uid: found.uid)
        }
        for saved in prioritizedDevices {
            guard let found = findAvailableDevice(uid: saved.id, modelUID: saved.modelUID),
                found.uid != saved.id || saved.modelUID == nil
            else { continue }
            let modelUID = getDeviceModelUID(deviceID: found.id)
            if found.uid != saved.id || modelUID != nil {
                rebindPrioritizedDevice(savedUID: saved.id, newUID: found.uid, newModelUID: modelUID)
            }
        }
    }

    private func setupApplicationMonitoring() {
        let workspace = NSWorkspace.shared
        updateRunningApplications(Set(workspace.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)))
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                self?.updateRunningApplications(Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)))
            }
            workspaceObservers.append(observer)
        }
    }

    private func setupDeviceChangeNotifications() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &address,
            DispatchQueue.main,
            listener
        )

        if status == noErr {
            deviceChangeListener = listener
        } else {
            logger.error("Failed to add device change listener: \(status, privacy: .public)")
        }

        address.mSelector = kAudioHardwarePropertyDefaultInputDevice
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reconcileInputAvailability()
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            systemObjectID, &address, DispatchQueue.main, defaultListener
        )
        if defaultStatus == noErr {
            defaultInputChangeListener = defaultListener
        } else {
            logger.error("Failed to add default input change listener: \(defaultStatus, privacy: .public)")
        }
    }

    private func handleDeviceListChange() {
        loadAvailableDevices()
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        let uid = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID)
        return uid as String?
    }

    func getDeviceModelUID(deviceID: AudioDeviceID) -> String? {
        let uid = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyModelUID)
        return uid as String?
    }

    func findAvailableDevice(uid: String, modelUID: String?) -> (id: AudioDeviceID, uid: String, name: String)?
    {
        if !uid.isEmpty, let found = availableDevices.first(where: { $0.uid == uid }) {
            return found
        }
        if let modelUID, !modelUID.isEmpty,
            let found = availableDevices.first(where: { getDeviceModelUID(deviceID: $0.id) == modelUID })
        {
            return found
        }
        return nil
    }

    private func rebindPrioritizedDevice(savedUID: String, newUID: String, newModelUID: String?) {
        prioritizedDevices.removeAll { $0.id == newUID && $0.id != savedUID }
        prioritizedDevices = prioritizedDevices.map { device in
            guard device.id == savedUID else { return device }
            return PrioritizedDevice(
                id: newUID, name: device.name, priority: device.priority, modelUID: newModelUID ?? device.modelUID,
                requirements: device.requirements)
        }
        savePrioritizedDevices()
    }

    private func updateCustomDeviceHints(deviceID: AudioDeviceID, uid: String, modelUID: String? = nil) {
        userDefaults.selectedAudioDeviceUID = uid
        userDefaults.selectedAudioDeviceModelUID = modelUID ?? getDeviceModelUID(deviceID: deviceID)
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for (selector, listener) in [
            (kAudioHardwarePropertyDevices, deviceChangeListener),
            (kAudioHardwarePropertyDefaultInputDevice, defaultInputChangeListener),
        ] {
            guard let listener else { continue }
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
            )
        }
    }

    private func createPropertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private func getCFStringDeviceProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> CFString? {
        guard deviceID != 0 else { return nil }

        var address = createPropertyAddress(selector: selector, scope: scope)
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var property = "" as CFString

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        if status != noErr {
            logger.error(
                "Failed to get device property \(selector, privacy: .public) for device \(deviceID, privacy: .public): \(status, privacy: .public)"
            )
            return nil
        }

        return property
    }

    func getUInt32DeviceProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        guard deviceID != 0 else { return nil }

        var address = createPropertyAddress(selector: selector, scope: scope)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var property: UInt32 = 0

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )
        guard status == noErr else { return nil }
        return property
    }

    /// The MacBook's internal microphone is physically disconnected when the lid closes.
    /// A headset-jack microphone also uses the built-in codec, so transport alone cannot identify lid-dependent inputs.
    func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        guard
            getUInt32DeviceProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyTransportType
            ) == kAudioDeviceTransportTypeBuiltIn
        else {
            return false
        }

        let uid = getDeviceUID(deviceID: deviceID)
        let dataSource = getUInt32DeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeInput
        )
        let internalMicrophoneSource = UInt32(kIOAudioSelectorControlSelectionValueInternalMicrophone)
        let externalMicrophoneSource = UInt32(kIOAudioSelectorControlSelectionValueExternalMicrophone)

        if dataSource == externalMicrophoneSource {
            return false
        }
        if dataSource == internalMicrophoneSource {
            return true
        }

        // Older Apple drivers may not implement data-source controls. Keep the known system
        // device UIDs only as a final compatibility fallback and fail open for unknown inputs.
        if uid == "BuiltInHeadphoneInputDevice" {
            return false
        }
        return uid == "BuiltInMicrophoneDevice"
    }

    func notifyDeviceChange() {
        notificationCenter.post(name: NSNotification.Name("AudioDeviceChanged"), object: nil)
    }
}
