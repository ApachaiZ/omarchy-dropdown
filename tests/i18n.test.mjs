import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

// en.json and fr.json must stay in strict parity: same keys, same plural
// variants, same positional placeholders. A missing translation renders the
// key itself in the UI.

const en = JSON.parse(readFileSync("i18n/en.json", "utf8"))
const fr = JSON.parse(readFileSync("i18n/fr.json", "utf8"))

function flatten(value, prefix, out) {
  for (const [key, entry] of Object.entries(value)) {
    const path = prefix ? prefix + "." + key : key
    if (entry && typeof entry === "object") flatten(entry, path, out)
    else out.set(path, String(entry))
  }
  return out
}

const enFlat = flatten(en, "", new Map())
const frFlat = flatten(fr, "", new Map())

test("en.json and fr.json have the same keys", () => {
  assert.deepEqual([...frFlat.keys()].sort(), [...enFlat.keys()].sort())
})

test("placeholders match for every key", () => {
  const placeholders = (value) => [...value.matchAll(/%(\d)/g)].map((match) => match[1]).sort()
  const mismatches = []
  for (const [key, value] of enFlat) {
    const other = frFlat.get(key) || ""
    if (placeholders(value).join(",") !== placeholders(other).join(","))
      mismatches.push(key)
  }
  assert.deepEqual(mismatches, [])
})

test("every value is a non-empty string", () => {
  for (const [key, value] of enFlat) assert.notEqual(value.trim(), "", key)
  for (const [key, value] of frFlat) assert.notEqual(value.trim(), "", key)
})
