import Foundation

/// EPUB structure/alignment unit tests deliberately use tiny synthetic
/// packages. The real EPUBCheck integration is covered in EPUBKit tests; this
/// stub lets these tests isolate ReadAloud behavior while exercising the same
/// bounded JSON-result path.
func makeEPUBCheckStub(
  in directory: URL, errors: Int = 0, exitStatus: Int = 0
) throws -> URL {
  let script = directory.appendingPathComponent("epubcheck-stub")
  let body = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "EPUBCheck vtest"
      exit 0
    fi
    report=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--json" ]; then
        shift
        report="$1"
      fi
      shift
    done
    printf '%s' '{"checker":{"checkerVersion":"test","nFatal":0,"nError":\(errors),"nWarning":0,"nUsage":0},"publication":{"ePubVersion":"3.0"}}' > "$report"
    exit \(exitStatus)
    """
  try Data(body.utf8).write(to: script)
  guard chmod(script.path, 0o700) == 0 else {
    throw CocoaError(.fileWriteNoPermission)
  }
  return script
}
