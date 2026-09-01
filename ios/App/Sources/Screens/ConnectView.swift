// ConnectView.swift — the connect flow (UX §12).
//
// Content column when no session exists; also reachable via ConnectSheet
// from the status capsule. Live endpoint list (2 s polling while visible),
// likely-match labeling, per-endpoint Connect, and the always-available
// Practice Mode entry with its profile picker. Failure states are the §14
// DeviceNotFound treatment (every port listed, so a cable problem is
// distinguishable from a wrong-port problem).

import SwiftUI
import FreakCore

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var endpoints: [HardwareEndpoint] = []
    @State private var selectedProfile: PracticeProfile = .factoryFresh

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "pianokeys.inverse")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No MicroFreak connected")
                .font(.title2.weight(.semibold))

            // Lower half: the actions (§13.1).
            endpointSection
            failureSection
            Divider().padding(.horizontal, 80)
            practiceSection
            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .task { await pollEndpoints() }
    }

    // ----------------------------------------------------------- endpoints

    @ViewBuilder
    private var endpointSection: some View {
        if endpoints.isEmpty {
            Text("Connect the MicroFreak by USB.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(endpoints) { endpoint in
                    endpointRow(endpoint)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func endpointRow(_ endpoint: HardwareEndpoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name).font(.body)
                if endpoint.likelyMatch {
                    Text("MicroFreak — likely match")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            if case .connecting(let name) = model.connection,
               name == endpoint.name {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") {
                    model.connectFailure = nil
                    model.connectHardware(endpoint)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // ------------------------------------------------------------- failures

    @ViewBuilder
    private var failureSection: some View {
        if let failure = model.connectFailure {
            VStack(alignment: .leading, spacing: 8) {
                switch failure {
                case .deviceNotFound(let inputs, let outputs):
                    Label("No MicroFreak found.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if inputs.isEmpty && outputs.isEmpty {
                        Text("No MIDI ports at all — check the cable.")
                            .font(.caption)
                    } else {
                        Text("MIDI inputs seen: "
                             + (inputs.isEmpty ? "none"
                                : inputs.joined(separator: ", ")))
                            .font(.caption)
                        Text("MIDI outputs seen: "
                             + (outputs.isEmpty ? "none"
                                : outputs.joined(separator: ", ")))
                            .font(.caption)
                    }
                case .transportUnavailable:
                    Label("MIDI is unavailable on this device.",
                          systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                default:
                    Label(failure.userMessage,
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    DisclosureGroup("Details") {
                        Text(String(describing: failure))
                            .font(.caption.monospaced())
                    }
                }
                Button("Retry") {
                    model.connectFailure = nil
                    model.connectHardware(nil)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
        }
    }

    // ------------------------------------------------------------- practice

    private var practiceSection: some View {
        VStack(spacing: 12) {
            Picker("Practice profile", selection: $selectedProfile) {
                ForEach(PracticeProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            Text(selectedProfile.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                model.startPractice(selectedProfile)
            } label: {
                Label("Practice Mode", systemImage: "waveform.path")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
    }

    // ------------------------------------------------------------- polling

    private func pollEndpoints() async {
        endpoints = HardwareTransportProvider.endpoints()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            endpoints = HardwareTransportProvider.endpoints()
        }
    }
}

/// The status-capsule route to the same flow, as a sheet (UX §12).
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConnectView()
                .navigationTitle("Connect")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

#Preview("Connect") {
    PreviewHost { model in
        ConnectView()
            .onAppear { model.disconnect() }
    }
}
