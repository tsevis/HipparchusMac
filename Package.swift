// swift-tools-version: 6.0
import PackageDescription

// The targets form a strict chain:
//
//     HipparchusGeometry  <-  HipparchusGEOS  <-  HipparchusData  <-  HipparchusRender
//
// The Python this is ported from had an import cycle between its data layer and
// its application layer that no test caught, because every test reached the
// application layer first. Expressing the layers as separate targets makes the
// same mistake a compile error instead.
let package = Package(
    name: "HipparchusMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HipparchusRender", targets: ["HipparchusRender"]),
        .executable(name: "hipparchus-cli", targets: ["hipparchus-cli"]),
    ],
    targets: [
        // GEOS, built by Scripts/build-geos-xcframework.sh and committed.
        // See Docs/GEOS.md and Vendor/geos/MANIFEST.txt.
        .binaryTarget(name: "CGEOS", path: "Vendor/geos/geos.xcframework"),

        // Pure arithmetic. No GEOS, no Core Graphics, no networking: contours,
        // Web Mercator and the grid are all portable numerics, and keeping them
        // dependency-free is what makes them fast to test.
        .target(name: "HipparchusGeometry"),

        // Planar geometry that genuinely needs an engine. The C API is confined
        // to this target; nothing above it sees an OpaquePointer.
        .target(
            name: "HipparchusGEOS",
            dependencies: ["CGEOS", "HipparchusGeometry"],
            linkerSettings: [
                // GEOS is C++ behind a C API, so the C++ runtime has to come along.
                .linkedLibrary("c++")
            ]
        ),

        .target(name: "HipparchusData", dependencies: ["HipparchusGeometry", "HipparchusGEOS"]),
        .target(name: "HipparchusRender", dependencies: ["HipparchusData"]),

        .executableTarget(name: "hipparchus-cli", dependencies: ["HipparchusRender"]),

        .testTarget(
            name: "HipparchusGeometryTests",
            dependencies: ["HipparchusGeometry"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "HipparchusGEOSTests",
            dependencies: ["HipparchusGEOS"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "HipparchusDataTests", dependencies: ["HipparchusData"]),
        .testTarget(name: "HipparchusRenderTests", dependencies: ["HipparchusRender"]),
    ]
)
