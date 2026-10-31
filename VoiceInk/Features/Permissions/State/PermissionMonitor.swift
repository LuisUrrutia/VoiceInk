import AVFoundation
import AppKit
import ApplicationServices
import Combine

struct PermissionSnapshot: Equatable {
    var microphone: CapturePermission
    var accessibility: Bool
    var screenRecording: Bool
}

struct PermissionClient {
    var read: () -> PermissionSnapshot

    static let live = PermissionClient {
        let microphone: CapturePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .restricted
        }
        return PermissionSnapshot(
            microphone: microphone,
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }
}

/// Reads macOS privacy permissions on activation and, while a setup surface is visible, every 400 ms
/// so its rows follow grants made in System Settings without returning to VoiceInk.
@MainActor
final class PermissionMonitor: ObservableObject {
    typealias RepeatingTimerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    static let shared = PermissionMonitor()
    static let liveRefreshInterval: TimeInterval = 0.4

    @Published private(set) var snapshot: PermissionSnapshot
    /// A grant made after this process saw Accessibility off can leave already-refused event taps
    /// unusable until relaunch; a grant present at launch cannot.
    private(set) var hasObservedUntrustedAccessibility: Bool

    private let client: PermissionClient
    private let makeTimer: RepeatingTimerFactory
    private var liveOwners: [ObjectIdentifier: WeakOwner] = [:]
    private var timer: AnyCancellable?
    private var activationSubscription: AnyCancellable?

    init(
        client: PermissionClient = .live,
        makeTimer: @escaping RepeatingTimerFactory = PermissionMonitor.mainRunLoopTimer,
        observesActivation: Bool = true
    ) {
        self.client = client
        self.makeTimer = makeTimer
        let initial = client.read()
        snapshot = initial
        hasObservedUntrustedAccessibility = !initial.accessibility
        if observesActivation {
            activationSubscription = LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
        }
    }

    var isLiveRefreshing: Bool { timer != nil }

    func refresh() {
        let current = client.read()
        if !current.accessibility { hasObservedUntrustedAccessibility = true }
        if current != snapshot { snapshot = current }
    }

    /// Delivers each Accessibility change on the main queue, after `snapshot` holds the new value.
    func observeAccessibilityChanges(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        $snapshot.map(\.accessibility).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { granted in MainActor.assumeIsolated { handler(granted) } }
    }

    /// Owners are held weakly; a released owner stops its refresh at the next tick.
    func setLiveRefresh(_ isActive: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if isActive {
            let isNew = liveOwners[id]?.object == nil
            liveOwners[id] = WeakOwner(object: owner)
            if isNew { refresh() }
        } else {
            liveOwners[id] = nil
        }
        updateTimer()
    }

    private func tick() {
        updateTimer()
        guard isLiveRefreshing else { return }
        refresh()
    }

    private func updateTimer() {
        liveOwners = liveOwners.filter { $0.value.object != nil }
        if liveOwners.isEmpty {
            timer = nil
        } else if timer == nil {
            timer = makeTimer(Self.liveRefreshInterval) { [weak self] in self?.tick() }
        }
    }

    static func mainRunLoopTimer(
        interval: TimeInterval, tick: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }

    private struct WeakOwner {
        weak var object: AnyObject?
    }
}
