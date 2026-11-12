import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { spawnSync } from "node:child_process"
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const require = createRequire(import.meta.url)
const Bounds = require("../js/Bounds.js")
const Model = require("../Model.js")

test("utf8ByteLength counts UTF-8 bytes, not UTF-16 units", () => {
  const samples = ["", "abc", "é", "€", "😀", "aé€😀z", "\uD800", "é\uD800é"]
  for (const sample of samples) {
    assert.equal(Bounds.utf8ByteLength(sample), Buffer.byteLength(sample, "utf8"), sample)
  }
})

test("producerCommand keeps the script constant and the command in argv", () => {
  const command = Bounds.producerCommand(["wl-paste", "--no-newline; rm -rf /"], 65536, 2)
  assert.equal(command[0], "bash")
  assert.equal(command[1], "-c")
  assert.equal(command[2], 'timeout -k 1 2 "$@" | head -c 65537; exit ${PIPESTATUS[0]}')
  assert.equal(command[3], "bash")
  assert.deepEqual(command.slice(4), ["wl-paste", "--no-newline; rm -rf /"])
})

test("producerCommand refuses empty commands and clamps the cap", () => {
  assert.deepEqual(Bounds.producerCommand([], 100, 2), [])
  const command = Bounds.producerCommand(["true"], -5, 0)
  assert.match(command[2], /head -c 2;/)
  assert.match(command[2], /timeout -k 1 2 /)
})

test("fileReadCommand bounds the file producer without a shell", () => {
  const command = Bounds.fileReadCommand("/tmp/a b;$(x).json", 1048576)
  assert.deepEqual(command, ["timeout", "-k", "1", "2", "head", "-c", "1048577", "/tmp/a b;$(x).json"])
})

test("clipboardCommand adds --primary only for the PRIMARY selection", () => {
  const normal = Bounds.clipboardCommand(false)
  const primary = Bounds.clipboardCommand(true)
  assert.deepEqual(normal.slice(4), ["wl-paste", "--no-newline"])
  assert.deepEqual(primary.slice(4), ["wl-paste", "--no-newline", "--primary"])
  assert.equal(normal[2], primary[2])
})

test("pushBounded caps a queue and drops the oldest entries", () => {
  let queue = []
  let dropped = 0
  for (let i = 0; i < 10; i++) {
    const pushed = Bounds.pushBounded(queue, i, 4)
    queue = pushed.queue
    dropped += pushed.dropped
  }
  assert.deepEqual(queue, [6, 7, 8, 9])
  assert.equal(dropped, 6)
})

test("pushCallback stamps entries and takeFreshCallbacks drops stale ones", () => {
  let queue = []
  const calls = []
  queue = Bounds.pushCallback(queue, () => calls.push("old"), 4, 1000).queue
  queue = Bounds.pushCallback(queue, () => calls.push("new"), 4, 9000).queue
  const taken = Bounds.takeFreshCallbacks(queue, 10000, 5000)
  assert.equal(taken.stale, 1)
  assert.equal(taken.callbacks.length, 1)
  taken.callbacks[0]()
  assert.deepEqual(calls, ["new"])
})

test("insertionVerdict refuses oversized and overflowing pastes", () => {
  assert.deepEqual(Bounds.insertionVerdict("a\r\nb\tc", 0, 200, 65536),
    { ok: true, text: "a b c" })
  assert.equal(Bounds.insertionVerdict("x".repeat(65537), 0, 200, 65536).reason, "tooLarge")
  assert.equal(Bounds.insertionVerdict("x".repeat(10), 195, 200, 65536).reason, "tooLong")
  assert.deepEqual(Bounds.insertionVerdict("x".repeat(5), 195, 200, 65536),
    { ok: true, text: "xxxxx" })
})

test("isCurrentGeneration discards results from superseded requests", () => {
  assert.equal(Bounds.isCurrentGeneration(3, 3), true)
  assert.equal(Bounds.isCurrentGeneration(2, 3), false)
  assert.equal(Bounds.isCurrentGeneration(null, 3), false)
  assert.equal(Bounds.isCurrentGeneration(undefined, 3), false)
})

test("singleLine keeps filter text on one line", () => {
  assert.equal(Bounds.singleLine("a\nb\r\nc\td"), "a b c d")
})

test("validateConfig caps the number of app entries", () => {
  const apps = {}
  for (let i = 0; i < Model.MAX_CONFIG_APPS + 40; i++) {
    apps["app." + i] = { enabled: true, key: "a" }
  }
  const result = Model.validateConfig(JSON.stringify({ schemaVersion: 1, apps }))
  // DEFAULT_CONFIG carries three system entries; the cap applies to file ones.
  assert.equal(Object.keys(result.config.apps).length, Model.MAX_CONFIG_APPS + 3)
  assert.ok(result.warnings.some((warning) => /Too many app entries/.test(warning)))
})

// ---- Real producer bound, through the exact command the plugin uses. ----
// A fake `wl-paste` is placed first in PATH; the user's clipboard is never
// touched and no Quickshell instance is involved.

function withFakeWlPaste(script, run) {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-bounds-"))
  const tool = join(dir, "wl-paste")
  writeFileSync(tool, "#!/bin/sh\n" + script + "\n")
  chmodSync(tool, 0o755)
  try {
    return run({ ...process.env, PATH: dir + ":" + process.env.PATH })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function runClipboardProducer(env) {
  const command = Bounds.clipboardCommand(false)
  const started = Date.now()
  const result = spawnSync(command[0], command.slice(1), {
    env,
    timeout: 15000,
    encoding: null
  })
  return { ...result, elapsed: Date.now() - started }
}

test("producer bound truncates a 1 MiB clipboard to cap+1 bytes", () => {
  withFakeWlPaste("head -c 1048576 /dev/zero | tr '\\0' a", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.stdout.length, Bounds.LIMITS.clipboardBytes + 1)
    assert.notEqual(result.status, 0, "SIGPIPE from head must not look like success")
    assert.ok(Bounds.utf8ByteLength(result.stdout.toString("utf8")) > Bounds.LIMITS.clipboardBytes)
  })
})

test("producer bound accepts a small clipboard and preserves its status", () => {
  withFakeWlPaste("printf 'hello world'", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 0)
    assert.equal(result.stdout.toString("utf8"), "hello world")
  })
})

test("producer bound times out a clipboard tool that never finishes", () => {
  withFakeWlPaste("sleep 30", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 124)
    assert.equal(result.stdout.length, 0)
    assert.ok(result.elapsed < 8000, "timeout must fire near the 2 s deadline")
  })
})

test("producer bound reports a failing clipboard tool", () => {
  withFakeWlPaste("exit 3", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 3)
    assert.equal(result.stdout.length, 0)
  })
})

test("producer bound reports a missing clipboard tool", () => {
  const command = Bounds.producerCommand(["dropdown-missing-tool-xyz"], 65536, 2)
  const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
  assert.equal(result.status, 127)
  assert.equal(result.stdout.length, 0)
})
