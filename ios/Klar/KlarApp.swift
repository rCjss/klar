import SwiftUI

// Klar fürs iPhone: Diktat mit Modellauswahl. Auf dem iPhone gibt es keine systemweiten Tastenkürzel und
// keinen Zwischenablage-Verlauf im Hintergrund – deshalb nur: antippen, sprechen, Text kopieren oder teilen.

@main
struct KlarApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(nil)
        }
        .onChange(of: phase) { _, newPhase in
            // Im Hintergrund darf iOS die App jederzeit beenden – laufendes Diktat sauber abschließen.
            // Ein Meeting läuft dagegen weiter (Hintergrundmodus „Audio“).
            if newPhase == .background { Dictation.shared.stop() }
        }
    }
}
