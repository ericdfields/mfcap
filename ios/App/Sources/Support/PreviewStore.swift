// PreviewStore.swift — the simulator-backed store every #Preview uses.
//
// Builds an AppModel in Practice Mode (Factory Fresh, UNPACED — previews
// want instant wire timing) against an ephemeral Documents sandbox, so
// previews are deterministic, offline, and never touch the user's library,
// backups, or history.

import Foundation
import SwiftUI

@MainActor
enum PreviewStore {
    /// A fresh practice-mode AppModel for previews.
    static func model(profile: PracticeProfile = .factoryFresh) -> AppModel {
        let model = AppModel(paths: .ephemeral())
        model.startPractice(profile, paced: false)
        return model
    }

    /// A model with no device — connect-screen and stale-cache previews.
    static func disconnectedModel() -> AppModel {
        AppModel(paths: .ephemeral())
    }
}

/// Wraps preview content with the environment the real hierarchy provides.
struct PreviewHost<Content: View>: View {
    @State private var model: AppModel
    private let content: (AppModel) -> Content

    init(profile: PracticeProfile = .factoryFresh,
         @ViewBuilder content: @escaping (AppModel) -> Content) {
        _model = State(initialValue: PreviewStore.model(profile: profile))
        self.content = content
    }

    var body: some View {
        content(model)
            .environment(model)
    }
}
