// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GotIt",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GotItDomain", targets: ["GotItDomain"]),
        .library(name: "GotItPersistence", targets: ["GotItPersistence"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "GotItDomain"),
        .target(name: "GotItPersistence", dependencies: ["GotItDomain", "CSQLite"], resources: [.process("Migrations")]),
        .testTarget(name: "GotItDomainTests", dependencies: ["GotItDomain"]),
        .testTarget(name: "GotItPersistenceTests", dependencies: ["GotItPersistence", "CSQLite"])
    ]
)
