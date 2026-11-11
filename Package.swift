// swift-tools-version: 6.0
//
// MaxFtp — client FTP / FTPS / SFTP / S3 natif pour macOS.
//
// Graphe des modules (les flèches pointent vers les dépendances) :
//
//   MaxFtpApp ──► MaxFtpFeatures ──► MaxFtpCore
//       │                                ▲
//       ├──► MaxFtpFTP ──────────────────┤
//       ├──► MaxFtpSFTP ─────────────────┤
//       ├──► MaxFtpS3 ───────────────────┤
//       └──► MaxFtpStorage ──────────────┘
//
// Règle d'or : MaxFtpCore ne dépend de rien (hors frameworks Apple), et
// MaxFtpFeatures ne connaît QUE MaxFtpCore. Les adaptateurs concrets (réseau,
// Keychain, fichiers) ne sont assemblés que dans MaxFtpApp (composition root).
// Voir ARCHITECTURE.md.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MaxFtp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MaxFtp", targets: ["MaxFtpApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        // Même fork que celui imposé par Citadel (sinon conflit d'identité SPM).
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
    ],
    targets: [
        // MARK: Domaine — modèles, contrats (protocols), logique pure.
        .target(
            name: "MaxFtpCore",
            swiftSettings: swiftSettings
        ),

        // MARK: Adaptateurs (infrastructure)
        .target(
            name: "MaxFtpStorage",
            dependencies: ["MaxFtpCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MaxFtpFTP",
            dependencies: [
                "MaxFtpCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MaxFtpSFTP",
            dependencies: [
                "MaxFtpCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            swiftSettings: swiftSettings
        ),

        // Stockage objet S3 / Cloudflare R2 : URLSession + signature SigV4 (CryptoKit).
        .target(
            name: "MaxFtpS3",
            dependencies: ["MaxFtpCore"],
            swiftSettings: swiftSettings
        ),

        // MARK: Présentation — vues SwiftUI + modèles de vue (@Observable).
        .target(
            name: "MaxFtpFeatures",
            dependencies: ["MaxFtpCore"],
            swiftSettings: swiftSettings
        ),

        // MARK: Exécutable — point d'entrée et assemblage des dépendances.
        .executableTarget(
            name: "MaxFtpApp",
            dependencies: ["MaxFtpCore", "MaxFtpStorage", "MaxFtpFTP", "MaxFtpSFTP", "MaxFtpS3", "MaxFtpFeatures"],
            swiftSettings: swiftSettings
        ),

        // MARK: Tests
        .target(
            name: "MaxFtpTestSupport",
            dependencies: ["MaxFtpCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpCoreTests",
            dependencies: ["MaxFtpCore", "MaxFtpTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpFTPTests",
            dependencies: ["MaxFtpFTP"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpSFTPTests",
            dependencies: ["MaxFtpSFTP"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpS3Tests",
            dependencies: ["MaxFtpS3"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpStorageTests",
            dependencies: ["MaxFtpStorage"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MaxFtpFeaturesTests",
            dependencies: ["MaxFtpFeatures", "MaxFtpTestSupport"],
            swiftSettings: swiftSettings
        ),
    ]
)
