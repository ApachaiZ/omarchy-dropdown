import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Keymap = require("../js/Keymap.js")

const commands = { help: "?", manage: "m", preview: "p", nextWindow: "w" }

test("Qt key codes map to stable names", () => {
  assert.equal(Keymap.nameForCode(32), "space")
  assert.equal(Keymap.nameForCode(16777220), "return")
  assert.equal(Keymap.nameForCode(16777235), "up")
  assert.equal(Keymap.nameForCode(16777234), "left")
  assert.equal(Keymap.nameForCode(65), "")
})

test("drawer columns adapt to the available width", () => {
  assert.equal(Keymap.columnsForWidth(320, 168), 1)
  assert.equal(Keymap.columnsForWidth(420, 168), 2)
  assert.equal(Keymap.columnsForWidth(780, 168), 3)
})

test("grid movement stays inside rows and exits upward", () => {
  assert.equal(Keymap.moveInGrid(0, 7, 3, 1, 0), 1)
  assert.equal(Keymap.moveInGrid(0, 7, 3, 0, 1), 3)
  assert.equal(Keymap.moveInGrid(1, 7, 3, 0, -1), -1)
  assert.equal(Keymap.moveInGrid(5, 7, 3, 1, 0), 5)
  assert.equal(Keymap.moveInGrid(6, 7, 3, 1, 0), 6)
  assert.equal(Keymap.moveInGrid(6, 7, 3, 0, 1), 6)
  assert.equal(Keymap.moveInGrid(2, 7, 3, 1, 0), 2)
  assert.equal(Keymap.moveInGrid(3, 7, 3, -1, 0), 3)
})

test("space toggles only when apps exist", () => {
  assert.equal(Keymap.paletteIntent({ key: "space", drawerCount: 4 }).action, "drawer-toggle")
  assert.equal(Keymap.paletteIntent({ key: "space", drawerCount: 0 }).action, "none")
})

test("escape collapses the drawer before the palette", () => {
  assert.equal(Keymap.paletteIntent({ key: "escape", drawerOpen: true }).action, "drawer-close")
  assert.equal(Keymap.paletteIntent({ key: "escape", drawerOpen: false }).action, "back")
})

test("enter commits, or activates the selected drawer card", () => {
  assert.deepEqual(Keymap.paletteIntent({ key: "return" }), { action: "commit" })
  assert.deepEqual(
    Keymap.paletteIntent({ key: "return", drawerOpen: true, drawerIndex: 2, drawerCount: 5 }),
    { action: "drawer-activate", index: 2 }
  )
})

test("arrows navigate the drawer and enter from the cards", () => {
  assert.deepEqual(
    Keymap.paletteIntent({ key: "down", drawerOpen: false, drawerCount: 5 }),
    { action: "drawer-open", index: 0 }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ key: "up", drawerOpen: false, drawerCount: 5 }),
    { action: "none" }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ key: "down", drawerOpen: true, drawerCount: 7, drawerIndex: 0, columns: 3 }),
    { action: "drawer-move", index: 3 }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ key: "up", drawerOpen: true, drawerCount: 7, drawerIndex: 1, columns: 3 }),
    { action: "drawer-exit" }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ key: "left", drawerOpen: false }),
    { action: "none" }
  )
})

test("commands win over app keys, then app keys, then free text", () => {
  assert.deepEqual(
    Keymap.paletteIntent({ text: "m", commands, appKeys: { m: "Mail" } }),
    { action: "command", name: "manage", key: "m" }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ text: "t", commands, appKeys: { t: "system.terminal" } }),
    { action: "app", key: "t", appId: "system.terminal" }
  )
  assert.deepEqual(
    Keymap.paletteIntent({ text: "z", commands, appKeys: {} }),
    { action: "text", key: "z", text: "z" }
  )
})
