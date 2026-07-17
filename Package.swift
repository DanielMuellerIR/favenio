// swift-tools-version: 6.0
// SwiftPM verwaltet hier nur die exakt gepinnte Sparkle-Abhängigkeit.
// Die beiden Apps werden weiterhin bewusst ohne Xcode-Projekt direkt mit
// swiftc gebaut; build-app.sh bettet das aufgelöste Framework ein.
import PackageDescription

let package = Package(
    name: "FavenioDependencies",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        // Ein Updater läuft mit Schreibrechten im Installationspfad.
        // Versionssprünge werden deshalb bewusst geprüft statt still übernommen.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        // Das Produkt wird von build-app.sh direkt an swiftc übergeben.
        // Dieser kleine Target hält die Abhängigkeit für SwiftPM explizit
        // erreichbar, damit `swift package resolve` sie samt Binärartefakt lädt.
        .target(
            name: "FavenioSparkleDependency",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "swiftpm"
        )
    ]
)
