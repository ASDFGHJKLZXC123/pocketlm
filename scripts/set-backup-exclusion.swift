#!/usr/bin/env swift

import Foundation
import Darwin

enum BackupExclusionError: Error, CustomStringConvertible {
    case usage
    case notARegularFile(String)
    case notExcluded(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: set-backup-exclusion.swift <set|check> MODEL_PATH"
        case let .notARegularFile(path):
            return "Not a regular model file: \(path)"
        case let .notExcluded(path):
            return "Backup exclusion is not set: \(path)"
        }
    }
}

let simulatorBackupAttribute = "com.apple.MobileBackup"

func hasSimulatorBackupAttribute(_ path: String) -> Bool {
    path.withCString { fileSystemPath in
        simulatorBackupAttribute.withCString { attributeName in
            let length = getxattr(fileSystemPath, attributeName, nil, 0, 0, 0)
            guard length > 0 else {
                return false
            }

            var value = [UInt8](repeating: 0, count: length)
            let read = value.withUnsafeMutableBytes { buffer in
                getxattr(fileSystemPath, attributeName, buffer.baseAddress, length, 0, 0)
            }
            return read == length && String(bytes: value, encoding: .utf8) == "1"
        }
    }
}

func setSimulatorBackupAttribute(_ path: String) throws {
    let value = Array("1".utf8)
    let result = path.withCString { fileSystemPath in
        simulatorBackupAttribute.withCString { attributeName in
            value.withUnsafeBytes { buffer in
                setxattr(fileSystemPath, attributeName, buffer.baseAddress, value.count, 0, 0)
            }
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw BackupExclusionError.usage
    }

    let mode = CommandLine.arguments[1]
    let path = CommandLine.arguments[2]
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
        throw BackupExclusionError.notARegularFile(path)
    }

    var url = URL(fileURLWithPath: path, isDirectory: false)
    switch mode {
    case "set":
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        // A Simulator data container is a host APFS path. Host Foundation can
        // report the iOS-only resource value as unsupported, so persist and
        // verify the CoreSimulator/iOS backup marker in that case.
        let foundationValue = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        if foundationValue.isExcludedFromBackup != true {
            try setSimulatorBackupAttribute(path)
        }
    case "check":
        break
    default:
        throw BackupExclusionError.usage
    }

    let current = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    guard current.isExcludedFromBackup == true || hasSimulatorBackupAttribute(path) else {
        throw BackupExclusionError.notExcluded(path)
    }

    print("Backup exclusion verified: \(path)")
} catch {
    FileHandle.standardError.write(Data("Backup exclusion failed: \(error)\n".utf8))
    exit(1)
}
