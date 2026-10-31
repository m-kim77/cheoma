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
        // 측정·기록·팬 커브·설치 명령처럼 화면 없이 확인할 수 있는 부분 (scripts/test.sh)
        .testTarget(name: "CheomaTests", dependencies: ["Cheoma", "CheomaShared"], path: "Tests/CheomaTests"),
    ]
)
