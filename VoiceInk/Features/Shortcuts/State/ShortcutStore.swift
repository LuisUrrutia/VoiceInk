import Foundation

enum ShortcutStore {
    static let shortcutDidChange = Notification.Name("ShortcutStoreShortcutDidChange")

    static func rawShortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = shortcutData(for: action) else { return nil }
        do {
            return try JSONDecoder().decode(Shortcut.self, from: data)
        } catch {
            ShortcutDiagnostics.storageError(action: action, operation: "decode")
            return nil
        }
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard action.isStored else {
            return nil
        }

        guard !isShortcutCleared(for: action) else {
            return nil
        }

        return rawShortcut(for: action)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        if let shortcut, let error = ShortcutValidator.validationError(for: shortcut, action: action) {
            ShortcutDiagnostics.notice("store action=\(action.storageName) result=rejected reason=\(error.diagnosticReason) shortcut={\(shortcut.diagnosticDescription)}")
            return
        }

        if let shortcut,
            let data = try? JSONEncoder().encode(shortcut)
        {
            UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
            UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
            ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
            ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
            ShortcutDiagnostics.notice("store action=\(action.storageName) result=saved shortcut={\(shortcut.diagnosticDescription)}")
        } else {
            if shortcut != nil {
                ShortcutDiagnostics.storageError(action: action, operation: "encode")
            }
            UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
            UserDefaults.standard.set(true, forKey: clearedUserDefaultsKey(for: action))
            ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
            ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
            ShortcutDiagnostics.notice("store action=\(action.storageName) result=cleared")
        }

        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    /// Applies bindings as one change: a key moving between these actions never collides with its previous holder.
    /// A binding that still conflicts is rejected as by `setShortcut`, and its action keeps its previous binding.
    static func setShortcuts(_ bindings: [(action: ShortcutAction, shortcut: Shortcut?)]) {
        let changes = bindings.filter { shortcut(for: $0.action) != $0.shortcut }
        let previous = Dictionary(changes.map { ($0.action, shortcut(for: $0.action)) }, uniquingKeysWith: { first, _ in first })
        for change in changes where previous[change.action] != nil {
            setShortcut(nil, for: change.action)
        }
        for change in changes {
            guard let target = change.shortcut else { continue }
            setShortcut(target, for: change.action)
            if shortcut(for: change.action) != target, let old = previous[change.action] ?? nil {
                setShortcut(old, for: change.action)
            }
        }
    }

    static func seedShortcut(
        _ shortcut: Shortcut,
        for action: ShortcutAction,
        replacingCleared: Bool = false
    ) {
        guard action.isStored,
            rawShortcut(for: action) == nil,
            replacingCleared || !isShortcutCleared(for: action)
        else {
            return
        }

        setShortcut(shortcut, for: action)
    }

    static func removeShortcutStorage(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        ShortcutDiagnostics.notice("store action=\(action.storageName) result=removed")
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    static func shortcuts(for actions: [ShortcutAction]) -> [ShortcutAction: Shortcut] {
        actions.reduce(into: [:]) { result, action in
            if let shortcut = shortcut(for: action) {
                result[action] = shortcut
            }
        }
    }

    private static func shortcutData(for action: ShortcutAction) -> Data? {
        UserDefaults.standard.data(forKey: action.userDefaultsKey)
    }

    static func isShortcutCleared(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.bool(forKey: clearedUserDefaultsKey(for: action))
    }

    private static func clearedUserDefaultsKey(for action: ShortcutAction) -> String {
        "\(action.userDefaultsKey)_cleared"
    }
}
