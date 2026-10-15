// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Klar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Klar",
            path: "Sources/Klar",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
