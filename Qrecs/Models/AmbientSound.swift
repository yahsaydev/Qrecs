import Foundation

struct AmbientAccent: Equatable, Hashable, Sendable {
    let hex: UInt32
}

enum AmbientSound: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case fire
    case birds
    case rain
    case waterfall
    case night

    var id: String { rawValue }

    var nameEN: String {
        switch self {
        case .fire: "Fire"
        case .birds: "Birdsong"
        case .rain: "Rain"
        case .waterfall: "Waterfall"
        case .night: "Night"
        }
    }

    var nameRU: String {
        switch self {
        case .fire: "Огонь"
        case .birds: "Пение птиц"
        case .rain: "Дождь"
        case .waterfall: "Водопад"
        case .night: "Ночь"
        }
    }

    var accent: AmbientAccent {
        switch self {
        case .fire: AmbientAccent(hex: 0xF28C45)
        case .birds: AmbientAccent(hex: 0x48A868)
        case .rain: AmbientAccent(hex: 0x59A9C9)
        case .waterfall: AmbientAccent(hex: 0x247CB3)
        case .night: AmbientAccent(hex: 0x5B4AA8)
        }
    }

    var resourceFileName: String { "\(rawValue).\(resourceExtension)" }
    var resourceBaseName: String { rawValue }
    var resourceExtension: String {
        switch self {
        case .night: "wav"
        default: "mp3"
        }
    }

    var author: String {
        switch self {
        case .fire, .waterfall: "Nox_Sound"
        case .birds: "Magnesus"
        case .rain: "_lynks"
        case .night: "Solar01"
        }
    }

    var itemURL: URL {
        switch self {
        case .fire: URL(string: "https://freesound.org/people/Nox_Sound/sounds/558967/")!
        case .birds: URL(string: "https://freesound.org/people/Magnesus/sounds/723913/")!
        case .rain: URL(string: "https://freesound.org/people/_lynks/sounds/595717/")!
        case .waterfall: URL(string: "https://freesound.org/people/Nox_Sound/sounds/637082/")!
        case .night: URL(string: "https://freesound.org/people/Solar01/sounds/662882/")!
        }
    }

    var sourceURL: URL {
        switch self {
        case .fire: URL(string: "https://cdn.freesound.org/previews/558/558967_9250976-hq.mp3")!
        case .birds: URL(string: "https://cdn.freesound.org/previews/723/723913_2008500-hq.mp3")!
        case .rain: URL(string: "https://cdn.freesound.org/previews/595/595717_2530992-hq.mp3")!
        case .waterfall: URL(string: "https://cdn.freesound.org/previews/637/637082_9250976-hq.mp3")!
        case .night:
            // The bundled WAV was converted from the original file downloaded from this item page.
            URL(string: "https://freesound.org/people/Solar01/sounds/662882/")!
        }
    }

    var sha256: String {
        switch self {
        case .fire: "62ee6ffe5dbfa1f8a5bd50cd7cb5d28c7953659e1234847fd47bd0e33c4d7889"
        case .birds: "9aebcb869cf37040c4588fc05d72bed197951aaa1beacb6874b379c69e379dbb"
        case .rain: "c42458d0383b82d5b03e09650ae3db75368d14f51702acf28c8125a23eadfa73"
        case .waterfall: "00ea8141c0c3cfb1b24477a91ba3f949081b8deb7aac9af188645cca3bcfd7b2"
        case .night: "9600c27a8c4f106530e53a7ca7e5af76b2cc657a366ae324ae79e68df4a7c98d"
        }
    }

    var licenseURL: URL {
        URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!
    }
}

struct AmbientChannelState: Equatable, Sendable {
    var isEnabled: Bool
    var volume: Float
}

struct AmbientMixState: Equatable, Sendable {
    var channels: [AmbientSound: AmbientChannelState]
    var masterVolume: Float
    var isPlaying: Bool
    var failureMessage: String?

    static let `default` = AmbientMixState(
        channels: Dictionary(
            uniqueKeysWithValues: AmbientSound.allCases.map {
                ($0, AmbientChannelState(isEnabled: false, volume: 0.5))
            }
        ),
        masterVolume: 0.5,
        isPlaying: false,
        failureMessage: nil
    )
}
