// NewCollectionSheet.swift — the create-from-device name prompt (UX addendum
// §26.2). A collection name is not a preset name, so the 23-char rule does
// not apply — the field is unrestricted. Practice banner when simulated.

import SwiftUI

struct NewCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewCollectionRequest

    @State private var name: String

    init(request: NewCollectionRequest) {
        self.request = request
        _name = State(initialValue: request.defaultName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if request.isPractice { PracticeBanner() }
                Form {
                    Section {
                        TextField("Collection name", text: $name)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Captures the current arrangement of all 512 "
                             + "slots. The library is not modified; the device "
                             + "is only read.")
                    }
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.createCollectionFromDevice(
                            name: name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("New collection") {
    PreviewHost { _ in
        NewCollectionSheet(request: NewCollectionRequest(
            defaultName: "Snapshot 2026-09-01", isPractice: true))
    }
}
