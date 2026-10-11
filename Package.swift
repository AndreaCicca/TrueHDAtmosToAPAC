// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrueHDAtmosToAPAC",
    platforms: [
        .macOS("26.0"),
        .tvOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "TrueHDAtmosToAPAC",
            targets: ["TrueHDAtmosToAPAC"]
        ),
        .executable(
            name: "apac-atmos-poc",
            targets: ["APACAtmosCLI"]
        )
    ],
    targets: [
        .target(
            name: "TrueHDAtmosToAPAC",
            dependencies: []
        ),
        .executableTarget(
            name: "APACAtmosCLI",
            dependencies: ["TrueHDAtmosToAPAC"]
        )
    ]
)
