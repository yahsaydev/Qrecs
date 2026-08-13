import Foundation

enum AppPathsError: Error, Equatable {
    case baseDirectoryMustBeFileURL
    case applicationSupportUnavailable
}

struct AppPaths: Equatable, Sendable {
    let rootDirectory: URL
    let audioCacheDirectory: URL
    let userDataDirectory: URL
    let userDatabaseURL: URL

    init(baseDirectory: URL) throws {
        guard baseDirectory.isFileURL else {
            throw AppPathsError.baseDirectoryMustBeFileURL
        }
        let base = baseDirectory.standardizedFileURL
        rootDirectory = base.appendingPathComponent("Qrecs", isDirectory: true)
        audioCacheDirectory = rootDirectory.appendingPathComponent("AudioCache", isDirectory: true)
        userDataDirectory = rootDirectory.appendingPathComponent("UserData", isDirectory: true)
        userDatabaseURL = userDataDirectory.appendingPathComponent("user.sqlite", isDirectory: false)
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> AppPaths {
        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppPathsError.applicationSupportUnavailable
        }
        return try AppPaths(baseDirectory: directory)
    }

    func prepareDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: audioCacheDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: userDataDirectory,
            withIntermediateDirectories: true
        )
    }
}
