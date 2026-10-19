import Foundation

/// Command-line options. Flags accept `--flag value` or `--flag=value`.
struct Options: Equatable {
    enum Action: Equatable { case run, help, version }

    var action = Action.run
    var socketPath: String?
    var port: UInt16?
    /// `--remote` (true) or `--no-remote` (false); nil follows settings.
    var remote: Bool?
    var loopback = false
    var pairingLink = false
    var webDirectory: String?
    var configDirectory: String?
    var stateDirectory: String?
    var serverName: String?
    var offline = false
    var verbose = false

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static let usage = """
    Usage: planmeterd [options]

    PlanMeter's headless host. Scans local coding-agent transcripts and serves
    the desktop control API on a Unix socket and, when remote access is on, the
    end-to-end encrypted API that phones and the web client use over Tailscale.

    Options:
      --socket PATH       Control socket. Default: $PLANMETER_CONTROL_SOCKET,
                          then $XDG_RUNTIME_DIR/planmeter/control.sock, then
                          /tmp/planmeter-$UID/control.sock
      --port N            Remote access port for this run (default: the saved
                          setting, 7787 unless changed)
      --remote            Serve remote access in this run even if it is off in
                          settings
      --no-remote         Never serve remote access in this run
      --loopback          Also listen on 127.0.0.1 (local testing; always on
                          on macOS)
      --pairing-link      Print a pairing link once remote access is listening.
                          The link is a secret; it goes to stdout only.
      --web-dir DIR       The web client's files (default: searched next to the
                          executable, in share/planmeter/web, then the source tree)
      --config-dir DIR    Settings directory (default: $XDG_CONFIG_HOME/planmeter)
      --state-dir DIR     State directory: scan and pricing caches, paired
                          devices, server key (default: $XDG_STATE_HOME/planmeter)
      --name NAME         Name phones show for this host (default: host name)
      --offline           Never use the network: no pricing refresh and no
                          Codex account-wide readings; report local data only
      --verbose           Log debug detail
      --version           Print the version and exit
      -h, --help          Print this help and exit

    Signals: SIGTERM or SIGINT shut down cleanly.
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(for flag: String, inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < arguments.count else { throw UsageError(description: "\(flag) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            var flag = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                flag = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }
            switch flag {
            case "-h", "--help": options.action = .help
            case "--version": options.action = .version
            case "--socket": options.socketPath = try value(for: flag, inline: inline)
            case "--port":
                let raw = try value(for: flag, inline: inline)
                guard let port = Int(raw), (1025...65535).contains(port) else {
                    throw UsageError(description: "--port must be between 1025 and 65535")
                }
                options.port = UInt16(port)
            case "--remote": options.remote = true
            case "--no-remote": options.remote = false
            case "--loopback": options.loopback = true
            case "--pairing-link": options.pairingLink = true
            case "--web-dir": options.webDirectory = try value(for: flag, inline: inline)
            case "--config-dir": options.configDirectory = try value(for: flag, inline: inline)
            case "--state-dir": options.stateDirectory = try value(for: flag, inline: inline)
            case "--name": options.serverName = try value(for: flag, inline: inline)
            case "--offline": options.offline = true
            case "--verbose": options.verbose = true
            default:
                throw UsageError(description: "unknown option \(argument)")
            }
            if inline != nil, ["--remote", "--no-remote", "--loopback", "--pairing-link", "--offline", "--verbose", "--version", "--help"].contains(flag) {
                throw UsageError(description: "\(flag) takes no value")
            }
            index += 1
        }
        return options
    }
}
