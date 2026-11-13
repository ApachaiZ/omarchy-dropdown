import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const ConfigFile = require("../js/ConfigFile.js")

test("encode ends with a newline and round-trips", () => {
  const text = ConfigFile.encode({ schemaVersion: 1, apps: {} })
  assert.ok(text.endsWith("\n"))
  assert.deepEqual(JSON.parse(text), { schemaVersion: 1, apps: {} })
})

test("isOwnWrite ignores the service's own save", () => {
  assert.equal(ConfigFile.isOwnWrite("{\"a\":1}\n", "{\"a\":1}\n"), true)
  assert.equal(ConfigFile.isOwnWrite("{\"a\":2}\n", "{\"a\":1}\n"), false)
  assert.equal(ConfigFile.isOwnWrite("", ""), true)
})

test("backup names carry milliseconds and a unique sequence", () => {
  const date = new Date(2026, 0, 2, 3, 4, 5, 6)
  const first = ConfigFile.backupName("/tmp/dropdown.json", date)
  const second = ConfigFile.backupName("/tmp/dropdown.json", date)
  // Two backups taken in the same second/millisecond must never share a name.
  assert.match(first, /^\/tmp\/dropdown\.json\.bak-20260102-030405006-\d+$/)
  assert.match(second, /^\/tmp\/dropdown\.json\.bak-20260102-030405006-\d+$/)
  assert.notEqual(first, second)
  assert.equal(ConfigFile.backupName("", date), "")
})

test("looksLikeConfig rejects truncated or non-JSON files", () => {
  assert.equal(ConfigFile.looksLikeConfig("{\"a\":1}"), true)
  assert.equal(ConfigFile.looksLikeConfig("{\"a\":"), false)
  assert.equal(ConfigFile.looksLikeConfig("[]"), false)
  assert.equal(ConfigFile.looksLikeConfig(""), false)
})

test("pruneCommand never interpolates the path into the shell string", () => {
  const argv = ConfigFile.pruneCommand("/home/me/.config/omarchy/dropdown.json")
  assert.equal(argv[0], "bash")
  assert.equal(argv[1], "-c")
  assert.equal(argv[3], "_")
  assert.equal(argv[4], "/home/me/.config/omarchy/dropdown.json")
  assert.ok(!argv[2].includes("/home/me"))
})

test("backupCommand bounds destination bytes and publishes atomically", () => {
  const command = ConfigFile.backupCommand("/tmp/src", "/tmp/dst", 1048576, 3)
  assert.equal(command[0], "bash")
  assert.equal(command[1], "-c")
  // The copy is a bounded read, not a source-only size check: the part can
  // never receive more than cap+1 bytes, and its real size is checked.
  assert.match(command[2], /timeout -k 1 "\$secs" head -c "\$\(\(cap \+ 1\)\)" -- "\$src" > "\$part"/)
  assert.match(command[2], /written=\$\(wc -c < "\$part"/)
  assert.match(command[2], /\[ "\$written" -le "\$cap" \] \|\| exit 75/)
  assert.match(command[2], /mv -- "\$part" "\$dest"/)
  assert.match(command[2], /trap cleanup EXIT/)
  // Every value travels as a positional parameter; the script is constant.
  assert.deepEqual(command.slice(3),
    ["bash", "/tmp/src", "/tmp/dst", "/tmp/dst.part", "1048576", "3"])
})
