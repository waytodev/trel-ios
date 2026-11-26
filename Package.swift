// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Trel",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "Trel", targets: ["Trel"]),
    ],
    dependencies: [
        // 2.6.1+: fixes a launch crash on iOS 26.5 (see Trel.podspec).
        .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.6.1"),
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
