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
    /// When any binding is still rejected, every action in the batch keeps its previous storage.
    @discardableResult
    static func setShortcuts(_ bindings: [(action: ShortcutAction, shortcut: Shortcut?)]) -> Bool {
        let changes = bindings.filter { shortcut(for: $0.action) != $0.shortcut }
        guard !changes.isEmpty else { return true }
        let defaults = UserDefaults.standard
        let snapshot = changes.map { change in
            (
                action: change.action,
                data: defaults.object(forKey: change.action.userDefaultsKey),
                cleared: defaults.object(forKey: clearedUserDefaultsKey(for: change.action))
            )
        }
        for change in changes where shortcut(for: change.action) != nil {
            setShortcut(nil, for: change.action)
        }
        for change in changes {
            if let target = change.shortcut {
                setShortcut(target, for: change.action)
            }
        }
        guard changes.contains(where: { shortcut(for: $0.action) != $0.shortcut }) else { return true }

        for entry in snapshot {
            defaults.set(entry.data, forKey: entry.action.userDefaultsKey)
            defaults.set(entry.cleared, forKey: clearedUserDefaultsKey(for: entry.action))
            NotificationCenter.default.post(name: shortcutDidChange, object: entry.action)
        }
        ShortcutDiagnostics.notice("store batch=\(changes.map(\.action.storageName)) result=rejected")
        return false
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
