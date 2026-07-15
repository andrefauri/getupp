//
//  ContentView.swift
//  Getupp
//
//  THROWAWAY debug UI — verifies Steps 1–3 on device.
//

import SwiftUI
import FamilyControls

struct ContentView: View {

    // Pull the ShieldManager that was injected in GetuppApp.
    @EnvironmentObject var shieldManager: ShieldManager

    // Controls whether the app-picker sheet is open.
    @State private var isPickerPresented = false

    // Breadcrumbs are read from UserDefaults on appear and when the user refreshes.
    @State private var breadcrumbs: [String] = []

    var body: some View {
        NavigationView {
            ScrollView {
            VStack(spacing: 24) {

                // -- Authorization status --
                GroupBox("Authorization") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Status:")
                            Spacer()
                            Text(statusText)
                                .bold()
                                .foregroundColor(statusColor)
                        }

                        Button("Request Authorization") {
                            Task { await shieldManager.requestAuthorization() }
                        }
                        .buttonStyle(.borderedProminent)
                        // No point tapping again once already approved.
                        .disabled(shieldManager.authorizationStatus == .approved)
                    }
                    .padding(.vertical, 4)
                }

                // -- App selection --
                GroupBox("App Selection") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Apps selected:")
                            Spacer()
                            Text("\(shieldManager.selectedAppCount)")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Categories selected:")
                            Spacer()
                            Text("\(shieldManager.selectedCategoryCount)")
                                .monospacedDigit()
                        }

                        Button("Choose Apps to Block") {
                            isPickerPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        // Picker requires authorization first.
                        .disabled(shieldManager.authorizationStatus != .approved)
                    }
                    .padding(.vertical, 4)
                }

                // -- Shield controls --
                GroupBox("Shield") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("State:")
                            Spacer()
                            Text(shieldManager.isShielded ? "BLOCKED" : "Unblocked")
                                .bold()
                                .foregroundColor(shieldManager.isShielded ? .red : .green)
                        }

                        HStack(spacing: 12) {
                            Button("Block Now") {
                                shieldManager.applyShield()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(shieldManager.isShielded || shieldManager.selectedAppCount + shieldManager.selectedCategoryCount == 0)

                            Button("Unblock Now") {
                                shieldManager.removeShield()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(!shieldManager.isShielded)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // -- Schedule controls --
                GroupBox("Schedule") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Monitoring:")
                            Spacer()
                            Text(shieldManager.isMonitoring ? "Active" : "Off")
                                .bold()
                                .foregroundColor(shieldManager.isMonitoring ? .green : .secondary)
                        }

                        if let start = shieldManager.scheduleStart,
                           let end   = shieldManager.scheduleEnd {
                            HStack {
                                Text("Window:")
                                Spacer()
                                Text("\(formatTime(start)) – \(formatTime(end))")
                                    .monospacedDigit()
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Debug Window\n(+2 min, 15m)") {
                                shieldManager.startDebugWindow()
                                breadcrumbs = GetuppShared.loadBreadcrumbs()
                            }
                            .buttonStyle(.borderedProminent)
                            .multilineTextAlignment(.center)
                            .disabled(shieldManager.authorizationStatus != .approved)

                            Button("Stop Schedule") {
                                shieldManager.stopMonitoring()
                                breadcrumbs = GetuppShared.loadBreadcrumbs()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!shieldManager.isMonitoring)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // -- Verification --
                GroupBox("Verification") {
                    NavigationLink(destination: CameraView()) {
                        Label("Verify I'm Out of Bed", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .padding(.vertical, 4)
                }

                // -- Extension breadcrumbs --
                GroupBox("Extension Log") {
                    VStack(alignment: .leading, spacing: 6) {
                        if breadcrumbs.isEmpty {
                            Text("No events yet")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            // Show newest first.
                            ForEach(breadcrumbs.reversed().prefix(6), id: \.self) { crumb in
                                Text(crumb)
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }

                        Button("Refresh Log") {
                            breadcrumbs = GetuppShared.loadBreadcrumbs()
                        }
                        .font(.caption)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

            }
            .padding()
            } // ScrollView
            .navigationTitle("GETUPP Debug")
            .onAppear {
                breadcrumbs = GetuppShared.loadBreadcrumbs()
            }

            // The system FamilyActivityPicker sheet.
            // It writes directly into shieldManager.activitySelection through the binding.
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $shieldManager.activitySelection
            )

            // Because the picker writes via a Binding, didSet on the @Published property
            // doesn't fire. We call saveSelection() explicitly here instead.
            // Note: iOS 16 onChange uses the "{ _ in }" single-parameter form.
            .onChange(of: shieldManager.activitySelection) { _ in
                shieldManager.saveSelection()
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ dc: DateComponents) -> String {
        let h = dc.hour ?? 0
        let m = dc.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }

    private var statusText: String {
        switch shieldManager.authorizationStatus {
        case .notDetermined: return "Not Determined"
        case .denied:        return "Denied"
        case .approved:      return "Approved"
        @unknown default:    return "Unknown"
        }
    }

    private var statusColor: Color {
        switch shieldManager.authorizationStatus {
        case .approved: return .green
        case .denied:   return .red
        default:        return .orange
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ShieldManager())
}
