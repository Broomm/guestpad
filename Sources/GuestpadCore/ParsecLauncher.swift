import Foundation

// The supported Parsec launcher has zero-filled space between its arm64
// load commands and its first section. Keep all slices and section offsets fixed.
enum ParsecLauncher {
    static let bridgeName = "libGuestpadReceive.dylib"
    static let bridgePath = "@executable_path/../Frameworks/" + bridgeName
    private static let arm64: UInt32 = 0x0100000c
    private static let loadDylib: UInt32 = 0x0c
    private static let segment64: UInt32 = 0x19

    static func loadsBridge(_ data: Data) -> Bool {
        (try? layout(in: data).hasBridge) == true
    }

    static func addingBridge(to data: Data) throws -> Data {
        let layout = try layout(in: data)
        guard !layout.hasBridge else { return data }
        let path = Array(bridgePath.utf8) + [0]
        let size = (24 + path.count + 7) & ~7
        let end = layout.commandsEnd
        guard end + size <= layout.firstSection,
              data[end..<(end + size)].allSatisfy({ $0 == 0 }) else {
            throw GuestpadError("This Parsec launcher has no safe space for the Guestpad bridge entry.")
        }

        var result = data
        result.put(loadDylib, at: end)
        result.put(UInt32(size), at: end + 4)
        result.put(24, at: end + 8)
        result.replaceSubrange((end + 24)..<(end + 24 + path.count), with: path)
        result.put(layout.commandCount + 1, at: layout.slice + 16)
        result.put(UInt32(end + size - layout.slice - 32), at: layout.slice + 20)
        return result
    }

    private static func layout(in data: Data) throws -> Layout {
        let unsupported = GuestpadError("Guestpad could not verify the Parsec launcher format.")
        guard data.count >= 32 else { throw unsupported }
        var start = 0
        var limit = data.count
        if data.u32(at: 0, bigEndian: true) == 0xcafebabe {
            let count = Int(data.u32(at: 4, bigEndian: true))
            guard count > 0, count <= (data.count - 8) / 20 else { throw unsupported }
            let matches = (0..<count).map { 8 + $0 * 20 }.filter {
                data.u32(at: $0, bigEndian: true) == arm64
            }
            guard matches.count == 1, let entry = matches.first else { throw unsupported }
            start = Int(data.u32(at: entry + 8, bigEndian: true))
            let length = Int(data.u32(at: entry + 12, bigEndian: true))
            guard start >= 8 + count * 20, start <= data.count, length <= data.count - start else { throw unsupported }
            limit = start + length
        }
        guard limit - start >= 32, data.u32(at: start) == 0xfeedfacf,
              data.u32(at: start + 4) == arm64, data.u32(at: start + 12) == 2 else { throw unsupported }
        let count = data.u32(at: start + 16)
        let size = Int(data.u32(at: start + 20))
        guard size <= limit - start - 32, Int(count) <= size / 8 else { throw unsupported }
        let end = start + 32 + size
        var cursor = start + 32
        var firstSection = limit
        var hasBridge = false
        for _ in 0..<count {
            guard end - cursor >= 8 else { throw unsupported }
            let command = data.u32(at: cursor)
            let length = Int(data.u32(at: cursor + 4))
            guard length >= 8, length % 8 == 0, length <= end - cursor else { throw unsupported }
            if command == segment64 {
                guard length >= 72 else { throw unsupported }
                let sections = Int(data.u32(at: cursor + 64))
                guard sections <= (length - 72) / 80 else { throw unsupported }
                for section in 0..<sections {
                    let offset = Int(data.u32(at: cursor + 72 + section * 80 + 48))
                    if offset > 0 {
                        guard offset >= end - start, offset < limit - start else { throw unsupported }
                        firstSection = min(firstSection, start + offset)
                    }
                }
            } else if command == loadDylib {
                guard length >= 24 else { throw unsupported }
                let offset = Int(data.u32(at: cursor + 8))
                guard offset >= 24, offset < length else { throw unsupported }
                let name = data[(cursor + offset)..<(cursor + length)].prefix { $0 != 0 }
                if name.elementsEqual(bridgePath.utf8) { hasBridge = true }
            }
            cursor += length
        }
        guard cursor == end, firstSection < limit else { throw unsupported }
        return Layout(slice: start, commandCount: count, commandsEnd: end, firstSection: firstSection, hasBridge: hasBridge)
    }

    private struct Layout {
        let slice: Int
        let commandCount: UInt32
        let commandsEnd: Int
        let firstSection: Int
        let hasBridge: Bool
    }
}

private extension Data {
    func u32(at offset: Int, bigEndian: Bool = false) -> UInt32 {
        let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    mutating func put(_ value: UInt32, at offset: Int) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }
}
