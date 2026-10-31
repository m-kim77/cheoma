import XCTest
import CheomaShared
@testable import Cheoma

@MainActor
final class FanCurveTests: XCTestCase {
    private let curve: [Double] = [0, 0, 0, 2000, 3000, 4000, 5000, 6000]   // 30 … 100°C

    func testLinearCurveInterpolates() {
        XCTAssertEqual(FanController.curveRPM(at: 65, values: curve, style: .linear), 2500)
        XCTAssertEqual(FanController.curveRPM(at: 20, values: curve, style: .linear), 0)
        XCTAssertEqual(FanController.curveRPM(at: 120, values: curve, style: .linear), 6000)
    }

    func testStepCurveHoldsUntilNextPoint() {
        XCTAssertEqual(FanController.curveRPM(at: 69.9, values: curve, style: .step), 2000)
        XCTAssertEqual(FanController.curveRPM(at: 70, values: curve, style: .step), 3000)
    }

    func testEditingKeepsCurveRising() {
        // 가운데 점을 올리면 오른쪽 점이 같이 오르고, 내리면 왼쪽 점이 같이 내려간다
        XCTAssertEqual(FanController.editing(curve, index: 3, to: 4500), [0, 0, 0, 4500, 4500, 4500, 5000, 6000])
        XCTAssertEqual(FanController.editing(curve, index: 5, to: 1000), [0, 0, 0, 1000, 1000, 1000, 5000, 6000])
    }
}

/// 관리자 셸에서 도는 설치 명령을 root 없이 앞부분(복사 · 서명 확인 · 설정 파일 만들기)까지 실제로 돌려 본다
@MainActor
final class HelperInstallCommandTests: XCTestCase {
    private var staging: URL!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("CheomaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
    }

    /// 설치 명령에서 root가 필요한 단계(launchctl, /Library에 설치) 앞까지만 남기고 만든 설정 파일을 출력하게 바꾼다
    private func dryRun(binary: URL, requirement: String, plist: Data) -> String {
        let statements = FanController.installCommand(stagedBinary: binary.path, helperRequirement: requirement, plist: plist)
            .components(separatedBy: "; ")
        let lastUserStep = statements.lastIndex { $0.contains("base64 -D") }!
        return (statements[...lastUserStep] + ["/bin/cat \"$tmp/plist\""]).joined(separator: "; ")
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private func samplePlist() throws -> Data {
        // 실제 요구사항처럼 큰따옴표와 작은따옴표가 섞인 값
        let plist: [String: Any] = ["Label": FanHelper.label,
                                    "ProgramArguments": ["/x", "--allow-requirement", #"identifier "a.b" and cdhash H"12ab" /* it's */"#]]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func testCopiesVerifiesAndWritesPlistThroughAppleScript() throws {
        let binary = staging.appendingPathComponent("helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let requirement = try XCTUnwrap(CodeSignature.designatedRequirement(ofFile: binary))
        let plist = try samplePlist()

        // 셸에서 바로
        let shell = try run("/bin/sh", ["-c", dryRun(binary: binary, requirement: requirement, plist: plist)])
        XCTAssertEqual(shell.status, 0)
        XCTAssertEqual(shell.output, plist)

        // 실제로 넘기는 것처럼 osascript의 do shell script를 거쳐서 (따옴표 처리 확인)
        let script = FanController.shellScript(dryRun(binary: binary, requirement: requirement, plist: plist),
                                               administratorPrompt: nil)
        let apple = try run("/usr/bin/osascript", ["-e", script])
        XCTAssertEqual(apple.status, 0)
        let decoded = try PropertyListSerialization.propertyList(from: apple.output, format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["ProgramArguments"] as? [String],
                       ["/x", "--allow-requirement", #"identifier "a.b" and cdhash H"12ab" /* it's */"#])
    }

    /// 암호 창이 떠 있는 동안 임시 폴더의 도우미가 바뀌면 설치하지 않아야 한다
    func testRefusesSwappedBinary() throws {
        let binary = staging.appendingPathComponent("helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let requirement = try XCTUnwrap(CodeSignature.designatedRequirement(ofFile: binary))
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: binary)

        let result = try run("/bin/sh", ["-c", dryRun(binary: binary, requirement: requirement, plist: samplePlist())])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }
}

final class CodeSignatureTests: XCTestCase {
    func testOwnProcessSatisfiesOwnRequirement() throws {
        let requirement = try XCTUnwrap(CodeSignature.designatedRequirementOfSelf())
        XCTAssertTrue(CodeSignature.process(getpid(), satisfies: requirement))
    }

    func testSignedBundleIsIntact() throws {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let requirement = try XCTUnwrap(CodeSignature.designatedRequirement(ofFile: app))
        XCTAssertTrue(CodeSignature.bundle(at: app, isIntactAndSatisfies: requirement))
        XCTAssertFalse(CodeSignature.bundle(at: app, isIntactAndSatisfies: #"identifier "io.example.not-this-one""#))
    }

    func testOtherRequirementIsRejected() {
        XCTAssertFalse(CodeSignature.process(getpid(), satisfies: #"identifier "io.example.not-this-one""#))
        XCTAssertFalse(CodeSignature.process(getpid(), satisfies: "not a requirement"))
    }
}
