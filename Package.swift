// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexQuotaWidget",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexQuotaWidget", targets: ["CodexQuotaWidget"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaWidget",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexQuotaWidgetTests",
            dependencies: ["CodexQuotaWidget"]
        )
    ]
)
