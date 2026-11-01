// swift-tools-version: 5.7
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint Legacy — all-in-one macOS utilities.
import PackageDescription

let package = Package(
    name: "Shuriken",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Shuriken", targets: ["Shuriken"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Shuriken",
            path: "Sources/VorssaintLegacy"
        ),
    ]
)
