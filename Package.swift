// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Klar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Klar",
            dependencies: ["WhisperWire"],
            path: "Sources/Klar",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),

        // Whisper läuft in einem eigenen Hilfsprozess. So bleibt die Hardened Runtime der App unangetastet
        // (keine fremden Bibliotheken im Prozess mit Mikrofon-, Bildschirm- und Bedienungshilfen-Freigabe),
        // und ein Absturz der Erkennung reißt die App nicht mit.
        .executableTarget(
            name: "KlarWhisper",
            dependencies: ["WhisperFramework", "WhisperWire"],
            path: "Sources/KlarWhisper",
            linkerSettings: [
                // In der App liegt das Framework unter Contents/Frameworks, der Helfer unter Contents/Helpers.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // Datenformat zwischen App und Hilfsprozess.
        .target(name: "WhisperWire", path: "Sources/WhisperWire"),

        // whisper.cpp als fertiges Framework. Liegt nicht im Repository – ./fetch-whisper.sh lädt es
        // (build.sh ruft das Skript selbst auf).
        .binaryTarget(name: "WhisperFramework", path: "Vendor/whisper.xcframework"),
    ]
)
