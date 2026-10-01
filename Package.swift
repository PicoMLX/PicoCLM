// swift-tools-version: 6.2
import PackageDescription

// Opt in at manifest evaluation time so the core builds without resolving MLX.
let enableMLX = Context.environment["PICO_CONTEXT_ENABLE_MLX"] == "1"
var products: [Product] = [.library(name: "PicoContext", targets: ["PicoContext"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "PicoContext"),
    .testTarget(name: "PicoContextTests", dependencies: ["PicoContext"]),
]
if enableMLX {
    products.append(.library(name: "PicoContextMLX", targets: ["PicoContextMLX"]))
    products.append(.executable(name: "ContextPlayground", targets: ["ContextPlayground"]))
    dependencies.append(.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"))
    dependencies.append(.package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"))
    targets.append(.target(name: "PicoContextMLX", dependencies: [
        "PicoContext",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
    ]))
    targets.append(.executableTarget(name: "ContextPlayground", dependencies: [
        "PicoContext", "PicoContextMLX",
    ], path: "Examples/ContextPlayground"))
    targets.append(.testTarget(name: "PicoContextMLXTests", dependencies: ["PicoContext", "PicoContextMLX"]))
}
let package = Package(
    name: "PicoContext", platforms: [.macOS(.v15), .iOS(.v18)],
    products: products, dependencies: dependencies, targets: targets,
    swiftLanguageModes: [.v6]
)
