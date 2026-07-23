// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Winnow",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Winnow", targets: ["Winnow"])
  ],
  targets: [
    .executableTarget(
      name: "Winnow",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "WinnowTests",
      dependencies: ["Winnow"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
