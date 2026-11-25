// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "boo_box",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "boo_box", targets: ["boo_box"]),
        .executable(name: "boobox-attach", targets: ["BooBoxAttach"]),
        .executable(name: "boobox-clone", targets: ["BooBoxClone"]),
        .executable(name: "boobox-proxy", targets: ["BooBoxProxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/loeschg/GhosttyKit", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "boo_box",
            dependencies: [
                .product(name: "GhosttyKit", package: "GhosttyKit"),
            ],
            path: "Sources/BooBox",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "BooBoxAttach",
            path: "Sources/BooBoxAttach"
        ),
        .executableTarget(
            name: "BooBoxClone",
            path: "Sources/BooBoxClone"
        ),
        .executableTarget(
            name: "BooBoxProxy",
            path: "Sources/BooBoxProxy"
        ),
    ]
)
