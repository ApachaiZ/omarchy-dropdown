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

test("backup names are stable and timestamped", () => {
  const date = new Date(2026, 0, 2, 3, 4, 5)
  assert.equal(ConfigFile.backupName("/tmp/dropdown.json", date), "/tmp/dropdown.json.bak-20260102-030405")
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
