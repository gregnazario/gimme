import Foundation
import GimmeCore

// CLI entry point. Real verb dispatch + passthrough added in Phase 7.
let gimme = Gimme()
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
try? gimme.run(command: command, args: Array(args.dropFirst()))
