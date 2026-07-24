// swift-tools-version:5.10
import PackageDescription

// Helper CLI di diarizzazione: isolato in un pacchetto SPM così la build
// principale dell'app resta una pipeline swiftc senza dipendenze.
let package = Package(
    name: "callt-diarizer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "callt-diarizer",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
