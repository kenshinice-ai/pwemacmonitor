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

/// A class, so that the iterator is released when the last reference goes — however the loop over
/// it ended. As a struct it was released only when `next()` ran off the end, and a caller that
/// returned on its first match kept the port. `ioFirstProperties("AppleSmartBattery")` did exactly
/// that once per sample: one Mach port leaked every interval on any Mac with a battery, until the
/// kernel ended the process without a crash report at about 267,700 of them — six days at the
/// default interval, in every release from 1.0.0 to 1.5.2. `pwemon --portcheck` holds the line.
final class IOServiceIterator: Sequence, IteratorProtocol {
    private var iterator: io_iterator_t = 0
    init?(_ serviceName: String) {
        guard let matching = IOServiceMatching(serviceName) else { return nil }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    }
    deinit { if iterator != 0 { IOObjectRelease(iterator) } }
    func next() -> (entry: io_registry_entry_t, name: String)? {
        guard iterator != 0 else { return nil }
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
    guard let it = IOServiceIterator(serviceName) else { return nil }
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

/// How many Mach port names this process holds. A few hundred is ordinary for an app; a number
/// that climbs with every sample is a leak, and the kernel ends the process when it gets large.
func machPortCount() -> Int {
    var names: mach_port_name_array_t?, types: mach_port_type_array_t?
    var nameCount: mach_msg_type_number_t = 0, typeCount: mach_msg_type_number_t = 0
    guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS else { return -1 }
    if let names {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                      vm_size_t(Int(nameCount) * MemoryLayout<mach_port_name_t>.size))
    }
    if let types {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                      vm_size_t(Int(typeCount) * MemoryLayout<mach_port_type_t>.size))
    }
    return Int(nameCount)
}

@inline(__always) func zeroDiv(_ a: Double, _ b: Double) -> Double { b == 0 ? 0 : a / b }
