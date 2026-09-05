import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public func getPiUserAgent() -> String {
    var info = utsname()
    uname(&info)
    let release = withUnsafeBytes(of: info.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let machine = withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let arch: String
    switch machine {
    case "aarch64", "arm64": arch = "arm64"
    case "x86_64", "amd64": arch = "x64"
    case "i386", "i686": arch = "ia32"
    default: arch = machine.hasPrefix("arm") ? "arm" : machine
    }
    #if canImport(Darwin)
    let platform = "darwin"
    #else
    let platform = "linux"
    #endif
    return "pi (\(platform) \(release); \(arch))"
}
