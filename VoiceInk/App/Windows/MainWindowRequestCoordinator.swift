import Foundation

final class MainWindowRequestCoordinator {
    private let notificationCenter: NotificationCenter
    private let showExistingWindow: () -> Bool
    private let prepareWindow: () -> Void
    private var observer: NSObjectProtocol?
    private var opener: (() -> Void)?
    private var hasPendingRequest = false

    init(
        notificationCenter: NotificationCenter = .default,
        showExistingWindow: @escaping () -> Bool,
        prepareWindow: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.showExistingWindow = showExistingWindow
        self.prepareWindow = prepareWindow
        observer = notificationCenter.addObserver(
            forName: .showMainWindowRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.requestWindow()
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    func configureOpener(_ opener: @escaping () -> Void) {
        self.opener = opener
        if hasPendingRequest { requestWindow() }
    }

    @discardableResult
    func requestWindow() -> Bool {
        if showExistingWindow() {
            hasPendingRequest = false
            return true
        }
        prepareWindow()
        guard let opener else {
            hasPendingRequest = true
            return false
        }
        hasPendingRequest = false
        opener()
        return true
    }
}
