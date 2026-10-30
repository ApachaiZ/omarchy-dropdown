import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const read = (name) => fs.readFileSync(path.join(root, name), "utf8")

test("manifest matches the Omarchy schema and every entry point exists", () => {
  const manifest = JSON.parse(read("manifest.json"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "apach.dropdown")
  assert.ok(manifest.version)
  assert.ok(manifest.name)
  assert.ok(manifest.author)
  assert.ok(manifest.license)
  assert.ok(Array.isArray(manifest.kinds))
  for (const kind of ["service", "overlay", "bar-widget"]) {
    assert.ok(manifest.kinds.includes(kind), "missing kind " + kind)
  }
  for (const [kind, file] of Object.entries(manifest.entryPoints)) {
    assert.ok(fs.existsSync(path.join(root, file)), "missing entry point " + kind + " -> " + file)
  }
  assert.equal(manifest.barWidget.allowMultiple, false)
  assert.ok(["left", "center", "right"].includes(manifest.barWidget.defaultSection))
})

test("example configuration is valid and keeps the documented defaults", () => {
  const raw = read("config/dropdown.example.json")
  const { config, warnings } = Model.validateConfig(raw)
  assert.deepEqual(warnings, [])
  assert.equal(config.settings.geometry.preset, "medium")
  assert.equal(config.settings.animations.mode, "slide+fade")
  assert.equal(config.apps["system.terminal"].key, "t")
  assert.equal(config.apps["system.agent"].key, "i")
  assert.equal(config.apps["system.files"].key, "f")
})

test("Hyprland integration binds both prefixes to the plugin and documents removal", () => {
  const lua = read("hypr/dropdown.lua")
  assert.match(lua, /SUPER \+ ALT \+ SEMICOLON/)
  assert.match(lua, /SUPER \+ SEMICOLON/)
  assert.match(lua, /omarchy-shell shell toggle apach\.dropdown/)
  assert.match(lua, /Set a prefix to nil to\s+-- disable it/)
  assert.doesNotMatch(lua, /pkill|killall/)
})

test("no shell interpolation of desktop entries exists in the QML", () => {
  for (const file of ["Service.qml", "Overlay.qml", "BarWidget.qml", "Model.js"]) {
    const source = read(file)
    assert.doesNotMatch(source, /bash\s+-lc|sh\s+-c|eval\s*\(|child_process/, "shell interpolation in " + file)
  }
})

test("the service never uses pkill/killall or global window classes to close", () => {
  const source = read("Service.qml")
  assert.doesNotMatch(source, /pkill|killall/)
  assert.match(source, /hl\.dsp\.window\.close/)
  assert.match(source, /address:/)
})
