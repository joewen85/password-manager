// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasswordManageriOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PasswordManageriOSCore",
            targets: ["PasswordManageriOSCore"]
        )
    ],
    targets: [
        .target(
            name: "PasswordManageriOSCore"
        ),
        .testTarget(
            name: "PasswordManageriOSCoreTests",
            dependencies: ["PasswordManageriOSCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
