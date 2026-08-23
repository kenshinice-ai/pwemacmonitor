import Foundation
import IOKit

// MARK: - sysctl

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func sysctlValue<T>(_ name: String, _ type: T.Type) -> T? {
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, value, &size, nil, 0) == 0 else { return nil }
    return value.pointee
}

// MARK: - IORegistry

struct IOServiceIterator: Sequence, IteratorProtocol {
    private var iterator: io_iterator_t = 0
    init?(_ serviceName: String) {
        guard let matching = IOServiceMatching(serviceName) else { return nil }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    }
    mutating func next() -> (entry: io_registry_entry_t, name: String)? {
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { IOObjectRelease(iterator); iterator = 0; return nil }
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buf)
        return (entry, String(cString: buf))
    }
}

func ioProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return dict
}

func ioFirstProperties(_ serviceName: String, named: String? = nil) -> [String: Any]? {
    guard var it = IOServiceIterator(serviceName) else { return nil }
    while let (entry, name) = it.next() {
        defer { IOObjectRelease(entry) }
        if let named, named != name { continue }
        if let props = ioProperties(entry) { return props }
    }
    return nil
}

// MARK: - dlsym

final class DynamicLibrary {
    let handle: UnsafeMutableRawPointer
    init?(_ path: String) {
        guard let h = dlopen(path, RTLD_NOW) else { return nil }
        handle = h
    }
    func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }
}

@inline(__always) func zeroDiv(_ a: Double, _ b: Double) -> Double { b == 0 ? 0 : a / b }
