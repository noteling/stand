import Foundation

/// Helpers for raw audio: mono, 16-bit, little-endian PCM held in `Data`.
public enum PCM {
    public static func seconds(_ pcm: Data, rate: Double) -> Double {
        Double(pcm.count / 2) / rate
    }

    public static func silence(seconds: Double, rate: Double) -> Data {
        Data(count: Int((seconds * rate).rounded()) * 2)
    }

    /// Root-mean-square level, out of 32768.
    public static func rms(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += s * s
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    public static func samples(_ pcm: Data) -> [Int16] {
        let count = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0..<count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }

    public static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) } // this Mac is little-endian
    }

    /// Linear-interpolation resampling. Good enough for a listenable recording.
    public static func resample(_ input: [Int16], from: Double, to: Double) -> [Int16] {
        guard from != to, !input.isEmpty else { return input }
        let count = Int(Double(input.count) * to / from)
        return (0..<count).map { i in
            let position = Double(i) * from / to
            let i0 = Int(position)
            let i1 = min(i0 + 1, input.count - 1)
            let fraction = position - Double(i0)
            return Int16((Double(input[i0]) * (1 - fraction) + Double(input[i1]) * fraction).rounded())
        }
    }

    /// Adds `source` into `target` starting at `offset`, clipping at 16-bit limits.
    static func mix(_ source: [Int16], into target: inout [Int16], at offset: Int) {
        guard offset < target.count else { return }
        for i in 0..<min(source.count, target.count - offset) {
            target[offset + i] = Int16(max(-32768, min(32767, Int(target[offset + i]) + Int(source[i]))))
        }
    }

    public static func writeWav(_ pcm: Data, rate: Double, to url: URL) throws {
        try wav(pcm, rate: rate).write(to: url)
    }

    /// Mono 16-bit PCM as the contents of a WAV file.
    public static func wav(_ pcm: Data, rate: Double) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(rate)); append(UInt32(rate) * 2) // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }

    /// Reads the PCM out of a mono 16-bit WAV file, which is all this app produces.
    public static func readWav(_ url: URL) throws -> (rate: Double, pcm: Data) {
        let file = try Data(contentsOf: url)
        guard file.count > 12, String(decoding: file[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: file[8..<12], as: UTF8.self) == "WAVE" else {
            throw StandError("\(url.lastPathComponent) is not a WAV file.")
        }
        func u16(_ at: Int) -> Int { Int(file[at]) | Int(file[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var rate = 0, channels = 0, bits = 0
        var pcm: Data?
        var offset = 12
        while offset + 8 <= file.count {
            let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                pcm = Data(file[body..<min(body + size, file.count)])
            }
            offset = body + size + size % 2
        }
        guard let pcm, channels == 1, bits == 16 else {
            throw StandError("\(url.lastPathComponent): expected mono 16-bit PCM, got \(channels) channel(s) at \(bits) bits.")
        }
        return (Double(rate), pcm)
    }
}
