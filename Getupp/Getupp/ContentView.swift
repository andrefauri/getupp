//
//  ContentView.swift
//  Getupp
//
//  THROWAWAY debug UI — only purpose is to verify Step 1 works on device.
//

import SwiftUI
import FamilyControls

struct ContentView: View {

    // Pull the ShieldManager that was injected in GetuppApp.
    @EnvironmentObject var shieldManager: ShieldManager

    // Controls whether the app-picker sheet is open.
    @State private var isPickerPresented = false

    var body: some View {
        NavigationView {
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

                Spacer()
            }
            .padding()
            .navigationTitle("GETUPP Debug")

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
