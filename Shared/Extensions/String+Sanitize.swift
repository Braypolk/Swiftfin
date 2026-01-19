//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

extension String {

    /// Returns a filesystem-safe version of the string by removing or replacing
    /// characters that are not allowed in file/directory names.
    var sanitizedForFilename: String {
        // Characters not allowed in filenames on most filesystems
        let illegalCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")

        // Replace illegal characters with dashes
        var sanitized = unicodeScalars
            .map { illegalCharacters.contains($0) ? "-" : String($0) }
            .joined()

        // Collapse multiple consecutive dashes into one
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }

        // Collapse multiple consecutive spaces into one
        while sanitized.contains("  ") {
            sanitized = sanitized.replacingOccurrences(of: "  ", with: " ")
        }

        // Trim leading/trailing whitespace and dashes
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Limit to 255 characters (filesystem limit)
        if sanitized.count > 255 {
            sanitized = String(sanitized.prefix(255))
        }

        // If the result is empty, use a fallback
        if sanitized.isEmpty {
            sanitized = "Untitled"
        }

        return sanitized
    }
}
