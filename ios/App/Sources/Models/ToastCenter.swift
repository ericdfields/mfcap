// ToastCenter.swift — transient result toasts, including the 10-second
// Undo toast after recoverable overwrites (UX §6.6).

import Foundation

struct Toast: Identifiable, Equatable {
    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    let id = UUID()
    let message: String
    let actionLabel: String?
    let action: (@MainActor () -> Void)?
    let isError: Bool
}

@MainActor @Observable
final class ToastCenter {
    private(set) var toasts: [Toast] = []

    func show(_ message: String, isError: Bool = false,
              actionLabel: String? = nil, duration: TimeInterval = 4,
              action: (@MainActor () -> Void)? = nil) {
        let toast = Toast(message: message, actionLabel: actionLabel,
                          action: action, isError: isError)
        toasts.append(toast)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            self.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}
