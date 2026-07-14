//
//  GetuppApp.swift
//  Getupp
//
//  Created by Andre Fauri on 14/07/26.
//

import SwiftUI

@main
struct GetuppApp: App {

    // @StateObject creates the ShieldManager once and keeps it alive for the app's lifetime.
    @StateObject private var shieldManager = ShieldManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject ShieldManager so any view in the hierarchy can access it.
                .environmentObject(shieldManager)
        }
    }
}
