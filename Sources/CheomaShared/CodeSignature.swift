import Foundation
import Security

/// 코드 서명의 지정 요구사항(designated requirement). 팬 도우미는 이 문자열을 만족하는 앱의 연결만 받는다.
/// 인증서로 서명했으면 "identifier … and certificate …"라 다시 빌드해도 그대로고,
/// ad-hoc 서명이면 "cdhash H\"…\""라 그 빌드 하나에만 맞는다 (업데이트하면 도우미를 다시 설치해야 한다).
public enum CodeSignature {
    /// 지금 실행 중인 이 프로그램의 요구사항
    public static func designatedRequirementOfSelf() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return designatedRequirement(of: staticCode)
    }

    /// 파일(실행 파일이나 .app)의 요구사항
    public static func designatedRequirement(ofFile url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return designatedRequirement(of: staticCode)
    }

    /// 실행 중인 프로세스가 요구사항을 만족하는지. pid는 재사용될 수 있어서 이것만으로 막지는 않고,
    /// 연결을 받을 때 미리 걸러 로그를 남기는 데 쓴다 (실제로 막는 건 NSXPCConnection.setCodeSigningRequirement).
    public static func process(_ pid: pid_t, satisfies requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// 디스크의 .app 번들이 서명된 그대로인지 (안에 든 실행 파일들까지), 그리고 요구사항을 만족하는지.
    /// 번들 안의 도우미 파일만 바꿔치기하면 번들 서명이 깨져서 여기서 걸린다
    public static func bundle(at url: URL, isIntactAndSatisfies requirementText: String) -> Bool {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    private static func designatedRequirement(of code: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}
