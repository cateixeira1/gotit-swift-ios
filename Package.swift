// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GotIt",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GotItDomain", targets: ["GotItDomain"]),
        .library(name: "GotItPersistence", targets: ["GotItPersistence"]),
        .library(name: "GotItCanvas", targets: ["GotItCanvas"]),
        .library(name: "GotItCanvasUI", targets: ["GotItCanvasUI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "GotItDomain"),
        .target(name: "GotItCanvas", dependencies: ["GotItDomain"]),
        .target(name: "GotItCanvasUI", dependencies: ["GotItDomain", "GotItCanvas"]),
        .target(name: "GotItPersistence", dependencies: ["GotItDomain", "CSQLite"], resources: [.process("Migrations")]),
        .testTarget(name: "GotItDomainTests", dependencies: ["GotItDomain"]),
        .testTarget(name: "GotItPersistenceTests", dependencies: ["GotItPersistence", "CSQLite"]),
        .testTarget(name: "GotItCanvasTests", dependencies: ["GotItCanvas"])
    ]
)
