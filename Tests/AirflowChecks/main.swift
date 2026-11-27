import Foundation

let t = Checks()
hotkeyChecks(t)
textProcessingChecks(t)
claudeChecks(t)
await pipelineChecks(t)
storageChecks(t)

print("\(t.failed == 0 ? "✔" : "✘") \(t.passed) checks passed, \(t.failed) failed")
exit(t.failed == 0 ? 0 : 1)
