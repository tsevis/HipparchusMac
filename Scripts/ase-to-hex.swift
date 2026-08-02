#!/usr/bin/env swift
//
// Read an Adobe Swatch Exchange (.ase) file and print its colours as hex.
//
//     swift Scripts/ase-to-hex.swift <file.ase> [more.ase …]
//
// Written because the palettes worth stealing from arrive as .ase, which is a
// binary format no shell tool reads, and the alternative was eyeballing `xxd`.
// In Swift rather than Python so it runs on the toolchain this project already
// builds with, and so the parsing is checkable by anyone reading the rest of
// the repository.
//
// The format, all big-endian:
//
//     "ASEF" · version major u16 · version minor u16 · block count u32
//     per block: type u16 · length u32 · payload
//       type 0x0001  a colour
//       type 0xC001  group start · 0xC002  group end
//     a colour's payload:
//       name length u16, in UTF-16 code units *including* the trailing NUL
//       name, UTF-16BE
//       model, four ASCII bytes: "RGB ", "CMYK", "LAB ", "Gray"
//       components, float32 each: 3, 4, 3 or 1 by model
//       colour type u16

import Foundation

struct Reader {
    let bytes: [UInt8]
    var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    mutating func f32() -> Float? {
        guard let raw = u32() else { return nil }
        return Float(bitPattern: raw)
    }

    mutating func ascii(_ count: Int) -> String? {
        guard remaining >= count else { return nil }
        defer { offset += count }
        return String(bytes: bytes[offset..<(offset + count)], encoding: .ascii)
    }

    /// UTF-16BE of `units` code units, with the trailing NUL dropped.
    mutating func utf16(_ units: Int) -> String? {
        guard remaining >= units * 2 else { return nil }
        var scalars: [UInt16] = []
        for index in 0..<units {
            let at = offset + index * 2
            scalars.append(UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]))
        }
        offset += units * 2
        while scalars.last == 0 { scalars.removeLast() }
        return String(decoding: scalars, as: UTF16.self)
    }
}

/// Clamp and convert to 0…255.
func channel(_ value: Float) -> Int {
    Int((min(max(value, 0), 1) * 255).rounded())
}

/// CMYK the naive way. These palettes are screen palettes; anything that comes
/// in as CMYK is being approximated and is flagged in the output so it can be
/// checked by eye rather than trusted.
func fromCMYK(_ c: Float, _ m: Float, _ y: Float, _ k: Float) -> (Int, Int, Int) {
    (channel((1 - c) * (1 - k)), channel((1 - m) * (1 - k)), channel((1 - y) * (1 - k)))
}

/// CIE L*a*b* to sRGB, D50, which is what Adobe writes.
func fromLAB(_ lightness: Float, _ a: Float, _ b: Float) -> (Int, Int, Int) {
    let fy = (Double(lightness) + 16) / 116
    let fx = fy + Double(a) / 500
    let fz = fy - Double(b) / 200
    func expand(_ t: Double) -> Double {
        t > 6.0 / 29 ? t * t * t : 3 * pow(6.0 / 29, 2) * (t - 4.0 / 29)
    }
    let x = 0.9642 * expand(fx), y = 1.0 * expand(fy), z = 0.8249 * expand(fz)

    let r = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
    let g = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
    let bl = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
    func gamma(_ v: Double) -> Int {
        let c = min(max(v, 0), 1)
        let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return Int((min(max(s, 0), 1) * 255).rounded())
    }
    return (gamma(r), gamma(g), gamma(bl))
}

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("could not read \(path)")
        continue
    }
    var reader = Reader(bytes: [UInt8](data))
    guard reader.ascii(4) == "ASEF" else {
        print("\(path): not an ASE file")
        continue
    }
    _ = reader.u16(); _ = reader.u16()
    guard let blocks = reader.u32() else { continue }

    print("\n=== \((path as NSString).lastPathComponent) — \(blocks) blocks ===")
    for _ in 0..<blocks {
        guard let type = reader.u16(), let length = reader.u32() else { break }
        let end = reader.offset + Int(length)
        defer { reader.offset = min(end, reader.bytes.count) }

        guard type == 0x0001 else { continue }
        guard let nameUnits = reader.u16(), let name = reader.utf16(Int(nameUnits)),
              let model = reader.ascii(4)
        else { continue }

        var rgb: (Int, Int, Int)?
        var note = ""
        switch model {
        case "RGB ":
            if let r = reader.f32(), let g = reader.f32(), let b = reader.f32() {
                rgb = (channel(r), channel(g), channel(b))
            }
        case "CMYK":
            if let c = reader.f32(), let m = reader.f32(), let y = reader.f32(), let k = reader.f32() {
                rgb = fromCMYK(c, m, y, k)
                note = "  (from CMYK, approximate)"
            }
        case "LAB ":
            if let l = reader.f32(), let a = reader.f32(), let b = reader.f32() {
                rgb = fromLAB(l * 100, a, b)
                note = "  (from Lab)"
            }
        case "Gray":
            if let g = reader.f32() {
                rgb = (channel(g), channel(g), channel(g))
            }
        default:
            note = "  (unknown model \(model))"
        }

        if let rgb {
            print(String(format: "#%02X%02X%02X   %3d,%3d,%3d   %@%@",
                         rgb.0, rgb.1, rgb.2, rgb.0, rgb.1, rgb.2, name, note))
        } else {
            print("?          \(name)\(note)")
        }
    }
}
