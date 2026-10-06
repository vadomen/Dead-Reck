import DriveLoggerCore
import Foundation

// inspect_log — summarise a DriveLogger recording on the Mac.
//
//   swift run inspect_log <file.jsonl.gz> [--csv <dir>]
//
// Prints the header, events per kind, achieved rates, gaps over 50 ms in the
// 100 Hz streams, OBD latency percentiles (t - requestT), `elm` outcome counts
// and the truncation report; `--csv` writes one CSV per kind for analysis in
// Python. Implemented in M1 (docs/PLAN.md §4.7).

FileHandle.standardError.write(Data("inspect_log: not implemented yet (M1)\n".utf8))
exit(EXIT_FAILURE)
