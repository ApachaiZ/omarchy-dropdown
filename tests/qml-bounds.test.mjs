import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

// Static invariants for the bounded-helper and bounded-paste work. These are
// behavioural guards, not string trivia: each one fails when the property that
// makes the code safe is removed.

const qmlFiles = ["Service.qml", "Overlay.qml"]
const service = readFileSync("Service.qml", "utf8")
const overlay = readFileSync("Overlay.qml", "utf8")
const allQml = qmlFiles.map((file) => readFileSync(file, "utf8")).join("\n") +
  readFileSync("BarWidget.qml", "utf8")

function findBlocks(text, opener) {
  const blocks = []
  let from = 0
  for (;;) {
    const start = text.indexOf(opener, from)
    if (start < 0) return blocks
    let index = text.indexOf("{", start)
    let depth = 0
    let end = index
    for (; end < text.length; end++) {
      const char = text[end]
      if (char === "{") depth++
      else if (char === "}") {
        depth--
        if (depth === 0) { end++; break }
      }
    }
    blocks.push(text.slice(start, end))
    from = end
  }
}

const component = readFileSync("components/BoundedProcess.qml", "utf8")

test("streams are decoded once from a bounded buffer, never per chunk", () => {
  // StdioCollector stores the raw bytes and decodes the whole bounded buffer;
  // SplitParser would decode each read separately and corrupt a multi-byte
  // character split across two chunks.
  assert.equal(/(^|\n)\s*SplitParser\s*\{/.test(allQml), false)
  assert.equal(findBlocks(component, "StdioCollector {").length, 2)
  assert.match(component, /stdout:\s*StdioCollector\s*\{/)
  assert.match(component, /stderr:\s*StdioCollector\s*\{/)
  assert.match(component, /id:\s*outCollector/)
  assert.match(component, /id:\s*errCollector/)
  // waitForEnd must be false: with true, dataChanged only fires at the end and
  // the cap could not stop memory growth.
  assert.equal((component.match(/^\s+waitForEnd:\s*false/gm) || []).length, 2)
  assert.equal(/waitForEnd:\s*true/.test(component), false)
  assert.match(component, /Bounds\.chunkOverflow\(text\.length, cap\)/)
  assert.equal(/SplitParser\s*\{/.test(component), false)
  assert.match(component, /onDataChanged:\s*root\._watchStream\(outCollector, root\.maxOutBytes\)/)
  assert.match(component, /onDataChanged:\s*root\._watchStream\(errCollector, root\.maxErrBytes\)/)
  // Exact byte length is rechecked before any caller can parse the text.
  assert.match(component, /Bounds\.utf8ByteLength\(outText\)\s*>\s*maxOutBytes/)
  assert.match(component, /Bounds\.utf8ByteLength\(errText\)\s*>\s*maxErrBytes/)
  // The only collector in the repository is inside the bounded wrapper.
  for (const file of qmlFiles) {
    assert.equal(readFileSync(file, "utf8").includes("StdioCollector"), false, file)
  }
})

test("no QML file instantiates a raw Process", () => {
  for (const file of qmlFiles) {
    assert.equal(/(^|\n)\s*Process\s*\{/.test(readFileSync(file, "utf8")), false, file)
  }
})

test("every helper uses a bounded component with a deadline and a cap", () => {
  const blocks = findBlocks(allQml, "BoundedProcess {")
  assert.ok(blocks.length >= 16, "expected every former Process to be wrapped")
  for (const block of blocks) {
    assert.match(block, /timeoutMs:\s*\d+/, block.slice(0, 60))
    assert.match(block, /maxOutBytes:/, block.slice(0, 60))
    assert.match(block, /maxErrBytes:/, block.slice(0, 60))
  }
})

test("queued starts use a bounded FIFO instead of a single overwritten slot", () => {
  assert.match(component, /property var _queue:\s*\[\]/)
  assert.equal(/_next\b/.test(component), false)
  assert.match(component, /_queue\.push\(/)
  assert.match(component, /_queue\.shift\(\)/)
  assert.match(component, /_queue\.length >= maxQueue/)
  assert.match(component, /function _beginNext\(\)/)
  assert.match(component, /function _terminate\(\)/)
  assert.match(component, /function _finalize\(code\)/)
  assert.match(component, /function _watchStream\(/)
})

test("onExited finalizes synchronously, without a deferred run boundary", () => {
  const processBlock = findBlocks(component, "Process {")[0]
  assert.match(processBlock, /onExited:\s*function\(code, status\)\s*\{[\s\S]*?root\._finalize\(code\)/)
  assert.equal(/Qt\.callLater/.test(processBlock), false)
})

test("a refused configuration is backed up before the deferred write", () => {
  assert.match(service, /id:\s*configBackupProc/)
  assert.match(service, /configBackupProc\.start\(\["timeout", "-k", "1", "5", "cp", "--"/)
  assert.match(service, /function finishRefusedBackup\(result\)/)
  assert.match(service, /function finishRefusedBackup\(result\)[\s\S]*?if \(!result\.ok\)[\s\S]{0,800}service\.configBackupFailed/)
  assert.match(service, /service\.writeConfigNow\(\)/)
  assert.match(service, /service\.configRefused \|\| service\.configBackupInFlight|service\.configBackupInFlight/)
  assert.equal(/service\.backupConfig\(\)\s*[\s\S]{0,40}service\.configRefused = false/.test(service), false)
})

test("clipboard start failure is reported and restoreAll invalidates the check", () => {
  assert.match(overlay, /if \(!pasteProc\.start\(Bounds\.clipboardCommand\(primary === true\), tag\)\)/)
  assert.match(overlay, /notice\.clipboardBusy/)
  assert.match(service, /service\.cancelShortcutRequest\(\)\s*\n\s*service\.currentAppId/)
})

test("large-output and dispatch helpers are producer-bounded on both streams", () => {
  const ids = ["clientsProc", "monitorsProc", "bindsVerifyProc", "bindsCheckProc",
    "dispatchProc", "batchProc", "launchArmProc", "pasteProc", "barMoveProc"]
  const blocks = findBlocks(allQml, "BoundedProcess {").filter((block) =>
    ids.some((id) => new RegExp("id:\\s*" + id + "\\b").test(block)))
  assert.equal(blocks.length, ids.length)
  for (const block of blocks) {
    assert.match(block, /producerBound:\s*true/)
    assert.match(block, /producerTimeoutSeconds:\s*\d+/)
  }
})

test("no helper is started through a bare running assignment", () => {
  const ids = [
    "clientsProc", "monitorsProc", "dispatchProc", "batchProc", "launchArmProc",
    "bindsCheckProc", "bindsVerifyProc", "cursorProc", "terminalIdProc", "filesIdProc",
    "configReadProc", "stateReadProc", "agentReadProc", "bindsReadProc", "barMoveProc",
    "barConfigReadProc", "pasteProc", "configStatProc", "stateStatProc"
  ]
  for (const id of ids) {
    const pattern = new RegExp("\\b" + id + "\\.running\\s*=")
    assert.equal(pattern.test(allQml), false, id)
  }
})

test("FileView is notification/write only, never an unbounded reader", () => {
  const blocks = findBlocks(allQml, "FileView {")
  assert.ok(blocks.length >= 4)
  for (const block of blocks) {
    assert.match(block, /preload:\s*false/, block.slice(0, 80))
    assert.equal(/\.(text|data)\s*\(/.test(block), false, block.slice(0, 80))
    assert.equal(/\bonLoaded\s*:/.test(block), false, block.slice(0, 80))
  }
})

test("the manage search field blocks every native paste gesture", () => {
  const blocks = findBlocks(overlay, "TextInput {").filter((block) => /id:\s*searchInput/.test(block))
  assert.equal(blocks.length, 1)
  const field = blocks[0]
  assert.match(field, /maximumLength:\s*Bounds\.LIMITS\.searchChars/)
  assert.match(field, /Keys\.priority:\s*Keys\.BeforeItem/)
  assert.match(field, /event\.matches\(StandardKey\.Paste\)/)
  assert.match(field, /event\.accepted\s*=\s*true/)
  assert.match(field, /overlay\.pasteFromClipboard\(false\)/)
})

test("middle-click PRIMARY is intercepted above the search field", () => {
  const rectangle = findBlocks(overlay, "Rectangle {")
    .filter((block) => /id:\s*searchInput/.test(block))
  assert.equal(rectangle.length, 1)
  assert.match(rectangle[0], /acceptedButtons:\s*Qt\.MiddleButton/)
  assert.match(rectangle[0], /overlay\.pasteFromClipboard\(true\)/)
})

test("clipboard reads use the bounded producer and a generation token", () => {
  assert.match(overlay, /Bounds\.clipboardCommand\(/)
  assert.match(overlay, /pasteGeneration/)
  assert.match(overlay, /Bounds\.isCurrentGeneration\(result\.tag, overlay\.pasteGeneration\)/)
  assert.match(overlay, /searchInput\.insert\(/)
  assert.equal(/Quickshell\.clipboardText/.test(allQml), false)
})

test("queues have caps, stale callbacks and failed helpers are drained", () => {
  assert.match(service, /Bounds\.pushCallback\(/)
  assert.match(service, /Bounds\.takeFreshCallbacks\(/)
  assert.match(service, /Bounds\.pushBounded\(service\.dispatchQueue/)
  assert.match(service, /Bounds\.LIMITS\.launchArmItems/)
  assert.match(service, /function handleClientsFailure/)
  assert.match(service, /function handleMonitorsFailure/)
})

test("shortcut and launch watchdogs really terminate their helper", () => {
  assert.match(service, /bindsCheckProc\.cancel\(\)/)
  assert.match(service, /launchGuardTimer\.restart\(\)/)
  assert.match(service, /launchGuardTimer\.stop\(\)/)
  assert.match(service, /if \(service\.launching\[appId\]\) return/)
})

test("a shortcut check result is bound to its request generation", () => {
  assert.match(service, /property int shortcutCheckGeneration/)
  assert.match(service, /bindsCheckProc\.start\(\["hyprctl", "binds", "-j"\], service\.shortcutCheckGeneration\)/)
  assert.match(service, /if \(!Bounds\.isCurrentGeneration\(result\.tag, service\.shortcutCheckGeneration\)\) return/)
  assert.match(service, /finishShortcutCheck\(result\.out, result\.tag\)/)
})

test("clipboard maps the producer timeout and failed start", () => {
  assert.match(overlay, /result\.timedOut \|\| result\.code === 124/)
  assert.match(overlay, /result\.startFailed \|\| result\.code === 126 \|\| result\.code === 127/)
})

test("a failed config read never creates defaults unless the file is absent", () => {
  assert.match(service, /Bounds\.fileStateCommand\(service\.configPath\)/)
  assert.match(service, /Bounds\.readFailurePolicy\(Bounds\.fileStateFromExit\(statResult\), failure\)/)
  assert.match(service, /if \(policy === "absent"\) service\.configAbsent\(\)/)
  assert.match(service, /property bool configRefused/)
  assert.match(service, /if \(service\.configRefused && explicit !== true\) return/)
  // The refused path no longer writes after a fire-and-forget backup: the
  // bounded backup process must finish first.
  assert.match(service, /function startRefusedBackup\(\)/)
  assert.match(service, /configBackupProc\.start\(\["timeout", "-k", "1", "5", "cp", "--"/)
  assert.match(service, /function finishRefusedBackup\(result\)[\s\S]*?service\.writeConfigNow\(\)/)
})

test("a refused state file is never rewritten automatically", () => {
  assert.match(service, /property bool stateWritable/)
  assert.match(service, /if \(!service\.stateWritable\) return/)
  assert.match(service, /if \(!service\.stateWritable\) \{/)
  assert.match(service, /stateRetryTimer\.restart\(\)/)
})
