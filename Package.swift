// swift-tools-version:5.5
// Il pacchetto serve per aprire e modificare il progetto in Xcode.
// Per creare l'app "Easy F12.app" usare ./scripts/build.sh
import PackageDescription

let package = Package(
    name: "EasyF12",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "EasyF12",
            path: "Sources/EasyF12"
        )
    ]
)
