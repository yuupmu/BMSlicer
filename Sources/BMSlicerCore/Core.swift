import Foundation
import AVFoundation
import CVorbis

public enum SliceError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public struct Grid: Equatable {
    public var denominator: Int
    public var triplet: Bool
    public init(_ denominator: Int = 16, triplet: Bool = false) { self.denominator = denominator; self.triplet = triplet }
    public var beats: Double { 4.0 / Double(denominator) * (triplet ? 2.0 / 3.0 : 1) }
    public func step(sampleRate: Double, bpm: Double) -> Double { sampleRate * 60 / bpm * beats }
    public func snap(_ frame: Int, sampleRate: Double, bpm: Double, total: Int) -> Int {
        let s = step(sampleRate: sampleRate, bpm: bpm)
        return min(total, max(0, Int((Double(frame) / s).rounded() * s + 0.5)))
    }
    public func boundaries(sampleRate: Double, bpm: Double, total: Int) -> [Int] {
        let s = step(sampleRate: sampleRate, bpm: bpm)
        guard s >= 1, total > 0 else { return [] }
        return (1...max(1, Int(ceil(Double(total) / s)))).compactMap { i in
            let f = Int((Double(i) * s).rounded()); return f > 0 && f < total ? f : nil
        }
    }
    public static func adaptive(pixelsPerSecond: Double, bpm: Double, triplet: Bool) -> Grid {
        let candidates = [32,16,8,4,2]
        return candidates.map { Grid($0, triplet: triplet) }.first { $0.beats * 60 / bpm * pixelsPerSecond >= 28 } ?? Grid(2, triplet: triplet)
    }
}

public struct EditState: Equatable {
    public var titles: [Int: String] = [:]
    public var cuts: [Int] = []
    public var selected: Set<Int> = []
    public var cursor: Int = 0
    public var range: Range<Int>?
    public init() {}
    public func segments(total: Int) -> [Range<Int>] {
        let edges = [0] + cuts + [total]
        return zip(edges, edges.dropFirst()).compactMap { $0 < $1 ? $0..<$1 : nil }
    }
    public mutating func split(at frames: [Int], total: Int) {
        cuts = Array(Set(cuts + frames.filter { $0 > 0 && $0 < total })).sorted()
        selected = []; range = nil
    }
    public mutating func rename(total: Int, template: String, start: Int, digits: Int = 1) throws {
        let clips = segments(total: total)
        let indices = clips.indices.filter { selected.isEmpty || selected.contains($0) }
        let names = try Naming.names(template: template, count: indices.count, start: start, digits: digits)
        for (index, name) in zip(indices, names) { titles[clips[index].lowerBound] = name }
    }
    public func outputNames(ranges: [Range<Int>], template: String, start: Int, digits: Int = 1) throws -> [String] {
        let fallback = try ranges.contains(where: { titles[$0.lowerBound] == nil }) ? Naming.names(template: template, count: ranges.count, start: start, digits: digits) : Array(repeating: "", count: ranges.count)
        let names = ranges.enumerated().map { titles[$0.element.lowerBound] ?? fallback[$0.offset] }
        guard Set(names.map { $0.lowercased() }).count == names.count else {
            throw SliceError.message("클립 제목이 중복됩니다. 시작 번호나 제목을 바꿔 주세요.")
        }
        return names
    }
    public mutating func join(total: Int) {
        let old = segments(total: total)
        let indices: Set<Int> = range.map { r in Set(old.indices.filter { old[$0].overlaps(r) }) } ?? selected
        let removed = Set(cuts.indices.filter { indices.contains($0) && indices.contains($0+1) }.map { cuts[$0] })
        cuts.removeAll { removed.contains($0) }
        titles = titles.filter { !removed.contains($0.key) }
        let selectedRanges = old.indices.filter { indices.contains($0) }.map { old[$0] }
        selected = Set(segments(total: total).enumerated().filter { pair in selectedRanges.contains { $0.overlaps(pair.element) } }.map { $0.offset })
        range = nil
    }
}

public enum Naming {
    public static func names(template: String, count: Int, start: Int, digits: Int = 1) throws -> [String] {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.lowercased().hasSuffix(".wav") ? String(trimmed.dropLast(4)) : trimmed
        guard !base.isEmpty, count > 0, start >= 0, start <= Int.max - count else { throw SliceError.message("이름과 시작 번호를 확인해 주세요.") }
        let token = base.contains("\\n")
        let names = (0..<count).map { i -> String in
            let number = String(start + i)
            let padded = String(repeating: "0", count: max(0, min(digits, 9) - number.count)) + number
            let name = token ? base.replacingOccurrences(of: "\\n", with: padded) : (count == 1 ? base : base + "_" + padded)
            return name.lowercased().hasSuffix(".wav") ? String(name.dropLast(4)) + ".wav" : name + ".wav"
        }
        for n in names {
            let stem = String(n.dropLast(4))
            let reserved = ["CON","PRN","AUX","NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
            guard n.utf8.count <= 240, !stem.isEmpty, !stem.hasSuffix("."), !stem.hasSuffix(" "), !reserved.contains(stem.components(separatedBy: ".")[0].uppercased()), !n.unicodeScalars.contains(where: { $0.value < 32 || "\\/:*?\"<>|".unicodeScalars.contains($0) }) else {
                throw SliceError.message("파일 이름에 사용할 수 없는 문자가 있습니다. \\n 외에는 \\ / : * ? \" < > | 를 사용할 수 없습니다.")
            }
        }
        guard Set(names.map { $0.lowercased() }).count == count else { throw SliceError.message("중복된 파일 이름입니다.") }
        return names
    }
}

public final class AudioData {
    public let samples: [[Float]]
    public let sampleRate: Double
    public let source: URL
    public let peaks: [[Float]]
    public var frames: Int { samples.first?.count ?? 0 }
    public var channels: Int { samples.count }
    public var duration: Double { Double(frames) / sampleRate }
    public init(samples: [[Float]], sampleRate: Double, source: URL) throws {
        guard sampleRate.isFinite, sampleRate >= 1000, sampleRate <= 768000, !samples.isEmpty, samples.count <= 8, let n = samples.first?.count, n > 0, samples.allSatisfy({ $0.count == n }) else { throw SliceError.message("지원하지 않는 오디오 형식입니다.") }
        self.samples = samples; self.sampleRate = sampleRate; self.source = source
        self.peaks = samples.map { channel in
            stride(from: 0, to: channel.count, by: 256).map { start in channel[start..<min(start+256, channel.count)].reduce(Float(0)) { max($0, abs($1.isFinite ? $1 : 0)) } }
        }
    }
    public static func load(_ url: URL) throws -> AudioData {
        if ["ogg", "mp3"].contains(url.pathExtension.lowercased()) {
            var ptr: UnsafeMutablePointer<Float>?; var channels: Int32 = 0; var rate: Int32 = 0; var frames: Int32 = 0
            let error = url.pathExtension.lowercased() == "ogg" ? bms_decode_vorbis(url.path, &ptr, &channels, &rate, &frames) : bms_decode_mp3(url.path, &ptr, &channels, &rate, &frames)
            guard error == 0, let p = ptr else { throw SliceError.message("압축 오디오를 읽지 못했습니다 (\(error)). MP3와 OGG Vorbis를 지원하며, 손상된 파일·Ogg Opus·디코딩 후 512MB를 넘는 파일은 지원하지 않습니다.") }
            defer { bms_free(p) }
            let data = (0..<Int(channels)).map { c in (0..<Int(frames)).map { p[$0 * Int(channels) + c] } }
            return try AudioData(samples: data, sampleRate: Double(rate), source: url)
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length * Int64(file.processingFormat.channelCount) <= 134217728 else { throw SliceError.message("빈 파일이거나 오디오가 너무 큽니다. 디코딩 후 512MB까지 지원합니다.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw SliceError.message("오디오 메모리를 할당하지 못했습니다.") }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { throw SliceError.message("PCM 오디오를 읽지 못했습니다.") }
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
        return try AudioData(samples: channels, sampleRate: buffer.format.sampleRate, source: url)
    }
    public func peak(channel: Int, from: Int, to: Int) -> Float {
        let a = max(0, min(frames-1, from)); let b = max(a+1, min(frames, to))
        if b-a < 256 { return samples[channel][a..<b].reduce(0) { max($0, abs($1.isFinite ? $1 : 0)) } }
        return peaks[channel][(a/256)...min(peaks[channel].count-1, (b-1)/256)].max() ?? 0
    }
    public func wav(range: Range<Int>, bits: Int = 24) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= frames, !range.isEmpty, [16,24].contains(bits) else { throw SliceError.message("잘못된 내보내기 범위입니다.") }
        let size = range.count * channels * (bits / 8)
        guard size < Int(UInt32.max)-36 else { throw SliceError.message("WAV 최대 크기를 초과했습니다.") }
        var result = Data(capacity: size + 44)
        func ascii(_ s: String) { result.append(contentsOf: s.utf8) }
        func u16(_ v: Int) { result.append(UInt8(v & 255)); result.append(UInt8((v >> 8) & 255)) }
        func u32(_ v: Int) { u16(v & 65535); u16((v >> 16) & 65535) }
        let padding = size % 2
        ascii("RIFF"); u32(size+36+padding); ascii("WAVEfmt "); u32(16); u16(1); u16(channels)
        u32(Int(sampleRate.rounded())); u32(Int(sampleRate.rounded()) * channels * bits / 8); u16(channels * bits / 8); u16(bits); ascii("data"); u32(size)
        let scale = Double(1 << (bits-1)); let maximum = Int(scale)-1
        for frame in range { for c in 0..<channels {
            let s = samples[c][frame]; let value = Int((Double(max(-1, min(1, s.isFinite ? s : 0))) * scale).rounded())
            let v = max(-Int(scale), min(maximum, value))
            result.append(UInt8(truncatingIfNeeded: v)); result.append(UInt8(truncatingIfNeeded: v >> 8))
            if bits == 24 { result.append(UInt8(truncatingIfNeeded: v >> 16)) }
        } }
        if padding != 0 { result.append(0) }
        return result
    }
    public func export(ranges: [Range<Int>], names: [String], directory: URL, bits: Int) throws -> [URL] {
        guard ranges.count == names.count, !names.isEmpty, Set(names.map{$0.lowercased()}).count == names.count else { throw SliceError.message("내보내기 목록이 올바르지 않습니다.") }
        let fm = FileManager.default
        let existing = Set(try fm.contentsOfDirectory(atPath: directory.path).map{$0.lowercased()})
        let urls = try names.map { name -> URL in
            guard URL(fileURLWithPath: name).lastPathComponent == name, !existing.contains(name.lowercased()) else { throw SliceError.message("같은 이름의 파일이 있습니다: \(name)\n이름 또는 저장 폴더를 바꿔 주세요.") }
            return directory.appendingPathComponent(name)
        }
        let staging = directory.appendingPathComponent(".bmslicer-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var completed: [URL] = []
        do {
            for i in ranges.indices { try wav(range: ranges[i], bits: bits).write(to: staging.appendingPathComponent(names[i]), options: .withoutOverwriting) }
            for i in ranges.indices { try fm.moveItem(at: staging.appendingPathComponent(names[i]), to: urls[i]); completed.append(urls[i]) }
        } catch { for url in completed { try? fm.removeItem(at: url) }; throw error }
        return urls
    }
}
