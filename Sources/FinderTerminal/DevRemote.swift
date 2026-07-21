import AppKit

/// Headless dev control via distributed notifications (no TCC permissions needed):
///   ...ImperatorFinderTerminal.toggle    — same as pressing the hotkey
///   ...ImperatorFinderTerminal.snapshot  — writes <object>.png + <object>.json
/// Used by build tooling to verify styling/geometry without keyboard or screen access.
final class DevRemote {
    private let onToggle: () -> Void
    private let onSnapshot: (String) -> Void
    private let onExec: (String) -> Void

    init(onToggle: @escaping () -> Void, onSnapshot: @escaping (String) -> Void,
         onExec: @escaping (String) -> Void) {
        self.onToggle = onToggle
        self.onSnapshot = onSnapshot
        self.onExec = onExec
        let c = DistributedNotificationCenter.default()
        c.addObserver(self, selector: #selector(toggle),
                      name: .init("com.goranimperator.ImperatorFinderTerminal.toggle"), object: nil)
        c.addObserver(self, selector: #selector(snapshot(_:)),
                      name: .init("com.goranimperator.ImperatorFinderTerminal.snapshot"), object: nil)
        c.addObserver(self, selector: #selector(exec(_:)),
                      name: .init("com.goranimperator.ImperatorFinderTerminal.exec"), object: nil)
    }

    @objc private func exec(_ note: Notification) {
        guard let cmd = note.object as? String, !cmd.isEmpty else { return }
        DispatchQueue.main.async { self.onExec(cmd) }
    }

    private var lastToggle = Date.distantPast

    @objc private func toggle() {
        DispatchQueue.main.async {
            // Distributed notifications can double-deliver; debounce.
            guard Date().timeIntervalSince(self.lastToggle) > 1.0 else { return }
            self.lastToggle = Date()
            self.onToggle()
        }
    }

    @objc private func snapshot(_ note: Notification) {
        let path = (note.object as? String) ?? "/tmp/ft-snapshot"
        DispatchQueue.main.async { self.onSnapshot(path) }
    }
}
