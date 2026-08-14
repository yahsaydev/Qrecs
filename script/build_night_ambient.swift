#!/usr/bin/env swift

import Foundation

enum NightLoopError: Error, CustomStringConvertible {
    case usage
    case invalidWAV(String)

    var description: String {
        switch self {
        case .usage:
            "usage: build_night_ambient.swift <pcm16-stereo-44100-input.wav> <output.wav>"
        case let .invalidWAV(reason):
            "invalid WAV: \(reason)"
        }
    }
}

func uint16(_ data: Data, at offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8)
}

func uint32(_ data: Data, at offset: Int) -> Int {
    uint16(data, at: offset) | (uint16(data, at: offset + 2) << 16)
}

func appendUInt16(_ value: Int, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

func appendUInt32(_ value: Int, to data: inout Data) {
    appendUInt16(value & 0xffff, to: &data)
    appendUInt16((value >> 16) & 0xffff, to: &data)
}

func appendASCII(_ value: String, to data: inout Data) {
    data.append(value.data(using: .ascii)!)
}

func readSamples(from url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          String(data: data[0..<4], encoding: .ascii) == "RIFF",
          String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
        throw NightLoopError.invalidWAV("missing RIFF/WAVE header")
    }

    var format: (audio: Int, channels: Int, sampleRate: Int, bits: Int)?
    var sampleBytes: Data?
    var offset = 12
    while offset + 8 <= data.count {
        let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
        let chunkSize = uint32(data, at: offset + 4)
        let payloadOffset = offset + 8
        guard payloadOffset + chunkSize <= data.count else {
            throw NightLoopError.invalidWAV("truncated chunk")
        }
        if chunkID == "fmt ", chunkSize >= 16 {
            format = (
                uint16(data, at: payloadOffset),
                uint16(data, at: payloadOffset + 2),
                uint32(data, at: payloadOffset + 4),
                uint16(data, at: payloadOffset + 14)
            )
        } else if chunkID == "data" {
            sampleBytes = Data(data[payloadOffset..<(payloadOffset + chunkSize)])
        }
        offset = payloadOffset + chunkSize + (chunkSize % 2)
    }

    guard let format,
          format.audio == 1,
          format.channels == 2,
          format.sampleRate == 44_100,
          format.bits == 16,
          let sampleBytes,
          sampleBytes.count.isMultiple(of: 4) else {
        throw NightLoopError.invalidWAV("expected PCM16 stereo at 44.1 kHz")
    }
    return stride(from: 0, to: sampleBytes.count, by: 2).map { index in
        Int16(bitPattern: UInt16(uint16(sampleBytes, at: index)))
    }
}

func makeLoop(from samples: [Int16], overlapFrames: Int = 44_100) throws -> [Int16] {
    let channels = 2
    let frameCount = samples.count / channels
    guard frameCount > overlapFrames * 2 else {
        throw NightLoopError.invalidWAV("recording is too short for the crossfade")
    }

    var output: [Int16] = []
    output.reserveCapacity((frameCount - overlapFrames) * channels)
    for frame in 0..<overlapFrames {
        let progress = Double(frame) / Double(overlapFrames - 1)
        let tailGain = cos(progress * .pi / 2)
        let headGain = sin(progress * .pi / 2)
        for channel in 0..<channels {
            let tail = Double(samples[((frameCount - overlapFrames + frame) * channels) + channel])
            let head = Double(samples[(frame * channels) + channel])
            let mixed = Int((tail * tailGain + head * headGain).rounded())
            output.append(Int16(clamping: mixed))
        }
    }
    output.append(contentsOf: samples[(overlapFrames * channels)..<((frameCount - overlapFrames) * channels)])
    return rotateToSmoothestBoundary(output, comparisonFrames: 4_410)
}

func rotateToSmoothestBoundary(_ samples: [Int16], comparisonFrames: Int) -> [Int16] {
    let channels = 2
    let frameCount = samples.count / channels
    var prefixSquares = Array(
        repeating: Array(repeating: 0.0, count: (frameCount * 2) + 1),
        count: channels
    )
    for doubledFrame in 0..<(frameCount * 2) {
        let sourceFrame = doubledFrame % frameCount
        for channel in 0..<channels {
            let value = Double(samples[(sourceFrame * channels) + channel])
            prefixSquares[channel][doubledFrame + 1] =
                prefixSquares[channel][doubledFrame] + (value * value)
        }
    }

    var bestFrame = 0
    var bestScore = Double.infinity
    for frame in 0..<frameCount {
        var jumpIsSmooth = true
        var score = 0.0
        let center = frame < comparisonFrames ? frame + frameCount : frame
        for channel in 0..<channels {
            let previousFrame = (frame + frameCount - 1) % frameCount
            let jump = abs(
                Int(samples[(frame * channels) + channel])
                    - Int(samples[(previousFrame * channels) + channel])
            )
            jumpIsSmooth = jumpIsSmooth && jump <= 512

            let leadingEnergy = prefixSquares[channel][center + comparisonFrames]
                - prefixSquares[channel][center]
            let trailingEnergy = prefixSquares[channel][center]
                - prefixSquares[channel][center - comparisonFrames]
            let leadingRMS = sqrt(leadingEnergy / Double(comparisonFrames))
            let trailingRMS = sqrt(trailingEnergy / Double(comparisonFrames))
            let referenceRMS = max(leadingRMS, trailingRMS, .leastNonzeroMagnitude)
            score = max(score, abs(leadingRMS - trailingRMS) / referenceRMS)
        }
        if jumpIsSmooth, score < bestScore {
            bestScore = score
            bestFrame = frame
        }
    }

    let split = bestFrame * channels
    return Array(samples[split...]) + Array(samples[..<split])
}

func writeWAV(samples: [Int16], to url: URL) throws {
    let channels = 2
    let sampleRate = 44_100
    let bytesPerSample = 2
    let dataSize = samples.count * bytesPerSample
    var data = Data(capacity: 44 + dataSize)
    appendASCII("RIFF", to: &data)
    appendUInt32(36 + dataSize, to: &data)
    appendASCII("WAVE", to: &data)
    appendASCII("fmt ", to: &data)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(channels, to: &data)
    appendUInt32(sampleRate, to: &data)
    appendUInt32(sampleRate * channels * bytesPerSample, to: &data)
    appendUInt16(channels * bytesPerSample, to: &data)
    appendUInt16(bytesPerSample * 8, to: &data)
    appendASCII("data", to: &data)
    appendUInt32(dataSize, to: &data)
    for sample in samples {
        appendUInt16(Int(UInt16(bitPattern: sample)), to: &data)
    }
    try data.write(to: url, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 3 else { throw NightLoopError.usage }
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    try writeWAV(samples: makeLoop(from: readSamples(from: inputURL)), to: outputURL)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
