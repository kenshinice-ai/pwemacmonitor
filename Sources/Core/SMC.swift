import Foundation
import IOKit

/// AppleSMC key reader (port of macmon's SMC bindings). The 80-byte KeyData struct is encoded
/// by hand so the layout is exactly the C layout regardless of Swift's struct rules.
final class SMC {
    struct KeyInfo { var size: UInt32; var type: UInt32; var attrs: UInt8 }
    struct Value { let key: String; let type: String; let data: [UInt8] }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]
    private static let keyDataSize = 80

    init?() {
        guard var it = IOServiceIterator("AppleSMC") else { return nil }
        while let (entry, name) = it.next() {
            defer { IOObjectRelease(entry) }
            if name == "AppleSMCKeysEndpoint" {
                if IOServiceOpen(entry, mach_task_self_, 0, &conn) != KERN_SUCCESS { return nil }
            }
        }
        if conn == 0 { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) + UInt32($1) } }
    static func fourccString(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }

    private func call(key: UInt32, data8: UInt8, data32: UInt32 = 0, info: KeyInfo? = nil) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.keyDataSize)
        input.withUnsafeMutableBytes { b in
            b.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            if let info {
                b.storeBytes(of: info.size, toByteOffset: 28, as: UInt32.self)
                b.storeBytes(of: info.type, toByteOffset: 32, as: UInt32.self)
                b[36] = info.attrs
            }
            b[42] = data8
            b.storeBytes(of: data32, toByteOffset: 44, as: UInt32.self)
        }
        var output = [UInt8](repeating: 0, count: Self.keyDataSize)
        var outSize = Self.keyDataSize
        let rc = input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in
                IOConnectCallStructMethod(conn, 2, i.baseAddress, Self.keyDataSize, o.baseAddress, &outSize)
            }
        }
        guard rc == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    func keyInfo(_ key: UInt32) -> KeyInfo? {
        if let c = infoCache[key] { return c }
        guard let out = call(key: key, data8: 9) else { return nil }
        let info = out.withUnsafeBytes { b in
            KeyInfo(size: b.load(fromByteOffset: 28, as: UInt32.self),
                    type: b.load(fromByteOffset: 32, as: UInt32.self), attrs: b[36])
        }
        infoCache[key] = info
        return info
    }

    func keyByIndex(_ index: UInt32) -> String? {
        guard let out = call(key: 0, data8: 8, data32: index) else { return nil }
        let k = out.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        return Self.fourccString(k)
    }

    func read(_ key: String) -> Value? {
        let k = Self.fourcc(key)
        guard let info = keyInfo(k), info.size <= 32,
              let out = call(key: k, data8: 5, info: info) else { return nil }
        return Value(key: key, type: Self.fourccString(info.type), data: Array(out[48..<48 + Int(info.size)]))
    }

    func readFloat(_ key: String) -> Float? {
        guard let v = read(key) else { return nil }
        return Self.numeric(v)
    }

    static func numeric(_ v: Value) -> Float? {
        let d = v.data
        switch v.type {
        case "flt ": return d.count == 4 ? d.withUnsafeBytes { $0.load(as: Float.self) } : nil
        case "fpe2": return d.count >= 2 ? Float((UInt16(d[0]) << 6) | (UInt16(d[1]) >> 2)) : nil
        case "ui8 ": return d.first.map(Float.init)
        case "ui16": return d.count >= 2 ? Float(UInt16(d[0]) << 8 | UInt16(d[1])) : nil
        case "ui32": return d.count >= 4 ? Float(UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) : nil
        case "sp78": return d.count >= 2 ? Float(Int16(bitPattern: UInt16(d[0]) << 8 | UInt16(d[1]))) / 256 : nil
        default: return nil
        }
    }

    func allKeys() -> [String] {
        guard let v = read("#KEY"), v.data.count >= 4 else { return [] }
        let count = UInt32(v.data[0]) << 24 | UInt32(v.data[1]) << 16 | UInt32(v.data[2]) << 8 | UInt32(v.data[3])
        return (0..<min(count, 8000)).compactMap(keyByIndex)
    }
}
