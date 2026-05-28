// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PasswordManagerMacOS",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "PasswordManagerMacOS",
            targets: ["PasswordManagerMacOSApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PasswordManagerMacOSApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PasswordManagerMacOSTests",
            dependencies: ["PasswordManagerMacOSApp"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
