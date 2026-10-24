import Foundation

/// A build_app.py error code (BuildError.code) in plain language: what went wrong and what to do next. The script's own
/// message is always shown under it, since it names the exact file, command or size.
struct ErrorText: Equatable {
    var title: String
    var next: String

    init(code: String?) {
        switch code {
        case "toolchain":
            title = String(localized: "Developer tools are missing")
            next = String(localized: "Install what the message below names, then try again.")
        case "input":
            title = String(localized: "One of the files can't be used")
            next = String(localized: "Check the files you picked: the base game as an XCI or NSP, and an update as an NSP or NSZ.")
        case "keys_or_dump":
            title = String(localized: "The game file could not be read")
            next = String(localized: "Use prod.keys from the console the game was dumped on, and check that the dump is complete.")
        case "wrong_game":
            title = String(localized: "This isn't a supported game file")
            next = String(localized: "Pick the base game of Tears of the Kingdom or Breath of the Wild, and its update as the update.")
        case "unsupported_version":
            title = String(localized: "This version isn't supported")
            next = String(localized: "Supported: Tears of the Kingdom 1.0.0 with no update or the 1.1.2, 1.2.1 or 1.4.3 update; Breath of the Wild 1.6.0 or 1.9.0.")
        case "hash_mismatch":
            title = String(localized: "The game data doesn't match")
            next = String(localized: "The dump may be incomplete, damaged or another version. Dump the game again.")
        case "fonts":
            title = String(localized: "The system fonts are needed")
            next = String(localized: "NSP files have no shared fonts: pick an unpacked firmware folder or a folder of extracted shared fonts.")
        case "disk_space":
            title = String(localized: "Not enough free space")
            next = String(localized: "Free up space on the drive that holds the game file, then try again.")
        case "mod":
            title = String(localized: "The mod could not be merged")
            next = String(localized: "Check that the mod is for this game version (docs/mods.md), or build without it.")
        case "platform":
            title = String(localized: "Not available for this target")
            next = String(localized: "Build the Mac app instead.")
        default:
            title = String(localized: "The build failed")
            next = String(localized: "Copy the full log and attach it to a bug report.")
        }
    }
}
