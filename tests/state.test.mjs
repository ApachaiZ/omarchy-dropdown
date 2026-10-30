import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const State = require("../js/State.js")

test("appState follows the managed-window lifecycle", () => {
  const entry = { hidden: false, special: "dropdown-a" }
  assert.equal(State.appState(null, false, "", false), "stopped")
  assert.equal(State.appState({ hidden: false }, false, "", false), "stopped")
  assert.equal(State.appState(entry, true, "", false), "visible")
  assert.equal(State.appState({ hidden: true }, true, "", false), "hidden")
  assert.equal(State.appState(entry, false, "", true), "launching")
  assert.equal(State.appState(entry, true, "boom", false), "error")
})

test("stateNote explains parked, closed and missing windows", () => {
  assert.equal(State.stateNote({ available: false }, null, null, ""), "Not configured")
  assert.equal(State.stateNote({ available: true }, null, null, "boom"), "boom")
  assert.equal(State.stateNote({ available: true }, null, null, ""), "")
  assert.equal(State.stateNote({ available: true }, { hidden: true, special: "ws" }, null, ""), "Parked on ws")
  assert.equal(
    State.stateNote({ available: true, launchAtLogin: true }, { hidden: true, special: "ws" }, null, ""),
    "Parked on ws · starts at login"
  )
  assert.equal(State.stateNote({ available: true }, { hidden: false }, null, ""), "Window closed")
  assert.equal(
    State.stateNote({ available: true }, { hidden: false }, { workspace: "3" }, ""),
    "On workspace 3"
  )
})


test("autoHideReason covers workspace switch, desktop and siblings", () => {
  const entry = { hidden: false }
  assert.equal(State.autoHideReason({ enabled: true, entry }), "focus")
  assert.equal(State.autoHideReason({ enabled: true, entry, paletteOpen: true, activeAddress: "0x2" }), "")
  assert.equal(
    State.autoHideReason({ enabled: true, entry, focusedName: "5", windowWs: "4", activeAddress: "0x2" }),
    "workspace"
  )
  assert.equal(
    State.autoHideReason({ enabled: true, entry, activeAddress: "0x2", entryAddress: "0x2" }),
    ""
  )
  // Pointer crossing to another output changes the focused workspace, but the
  // managed window still owns keyboard focus: do not treat it as focus loss.
  assert.equal(
    State.autoHideReason({
      enabled: true, entry, focusedName: "1", windowWs: "2",
      activeAddress: "0x2", entryAddress: "0x2"
    }),
    ""
  )
  assert.equal(
    State.autoHideReason({ enabled: true, entry, activeAddress: "0x2", entryAddress: "0x1", activeIsSibling: true }),
    ""
  )
  assert.equal(State.autoHideReason({ enabled: false, entry }), "")
  assert.equal(State.autoHideReason({ enabled: true }), "")
})
