// Entry point for the `headroom` CLI (docs/DECISIONS.md, docs/cli.md).
import Foundation

let code = await HeadroomCLI.run(Array(CommandLine.arguments.dropFirst()))
exit(code)
