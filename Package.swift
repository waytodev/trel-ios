// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Trel",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "Trel", targets: ["Trel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Trel",
            dependencies: [
                .product(name: "Recording", package: "KSCrash"),
            ],
            path: "Sources/Trel",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
    ]
)
