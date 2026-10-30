// swift-tools-version:5.5
// Il pacchetto serve per aprire e modificare il progetto in Xcode.
// Per creare l'app "Easy F24.app" usare ./scripts/build.sh
import PackageDescription

let package = Package(
    name: "EasyF24",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "EasyF24",
            path: "Sources/EasyF24"
        )
    ]
)
