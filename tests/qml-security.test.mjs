import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"

// Regression guard for the marketplace security review: dynamic strings
// (window titles in particular) must never be interpreted as rich text. A
// title containing <img src="..."> made the shell fetch a remote URL.
const files = [
  "Overlay.qml",
  "BarWidget.qml",
  ...readdirSync("components")
    .filter((name) => name.endsWith(".qml"))
    .map((name) => "components/" + name)
]

test("every QML Text is plain text", () => {
  const failures = []
  for (const file of files) {
    const lines = readFileSync(file, "utf8").split("\n")
    for (let i = 0; i < lines.length; i++) {
      const match = /^(\s*)Text\s*\{\s*$/.exec(lines[i])
      if (!match) continue
      const expected = match[1] + "  textFormat: Text.PlainText"
      if (lines[i + 1] !== expected) {
        failures.push(`${file}:${i + 1} (missing ${expected.trim()})`)
      }
    }
  }
  assert.deepEqual(failures, [], "Text elements must set Text.PlainText")
})

test("rich text is never requested explicitly", () => {
  for (const file of files) {
    const text = readFileSync(file, "utf8")
    assert.equal(/Text\.(AutoText|RichText|StyledText)/.test(text), false, file)
  }
})
