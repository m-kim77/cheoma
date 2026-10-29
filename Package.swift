// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cheoma",
    platforms: [.macOS(.v14)],
    targets: [
        // SMC 접근과 팬 도우미 XPC 규약 (앱과 관리자 권한 도우미가 같이 쓴다)
        .target(name: "CheomaShared", path: "Sources/CheomaShared"),
        .executableTarget(name: "Cheoma", dependencies: ["CheomaShared"], path: "Sources/Cheoma"),
        // 팬 속도를 바꾸는 관리자 권한 도우미 (launchd 데몬으로 설치된다)
        .executableTarget(name: "CheomaFanHelper", dependencies: ["CheomaShared"], path: "Sources/CheomaFanHelper"),
    ]
)
