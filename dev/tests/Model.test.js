// Run with: dev/run.sh test  (or node --test dev/tests/)
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

// Model.js is a QML JavaScript library (".pragma library"); evaluate it in a sandbox.
const src = readFileSync(new URL("../../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
const M = {}
vm.runInNewContext(src + "\nthis.parseStatus = parseStatus; this.parseQuota = parseQuota; this.barText = barText; this.stateIcon = stateIcon; this.isUrgent = isUrgent; this.percent = percent; this.formatBytes = formatBytes; this.shortenHome = shortenHome; this.shellQuote = shellQuote; this.neutralizeMarkup = neutralizeMarkup; this.emptyStatus = emptyStatus", M)

test("parseStatus accepts the CLI JSON and normalises numbers", () => {
  const st = M.parseStatus('{"state":"mounted","mounted":true,"cacheBytes":"92436","cacheMaxBytes":16106127360,"pendingUploads":"2","mountpoint":"/home/x/GoogleDrive"}')
  assert.equal(st.state, "mounted")
  assert.equal(st.cacheBytes, 92436)
  assert.equal(st.pendingUploads, 2)
  assert.equal(st.mountpoint, "/home/x/GoogleDrive")
})

test("parseStatus rejects garbage and unknown states", () => {
  assert.equal(M.parseStatus(""), null)
  assert.equal(M.parseStatus("not json"), null)
  assert.equal(M.parseStatus("[1,2]"), null)
  assert.equal(M.parseStatus('{"state":"weird"}').state, "unknown")
})

test("parseQuota", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(M.parseQuota('{"total":100,"used":40,"free":60}'))), { used: 40, total: 100, free: 60, trashed: 0 })
  assert.equal(M.parseQuota("{}"), null)
  assert.equal(M.parseQuota("nope"), null)
})

test("barText shows the upload badge only while mounted", () => {
  const mounted = Object.assign(M.emptyStatus(), { state: "mounted", pendingUploads: 3 })
  assert.ok(M.barText(mounted).endsWith(" 3"))
  const stopped = Object.assign(M.emptyStatus(), { state: "stopped", pendingUploads: 3 })
  assert.equal(M.barText(stopped), M.stateIcon("stopped"))
  assert.equal(M.barText(null), M.stateIcon("unknown"))
})

test("isUrgent only for errors", () => {
  assert.equal(M.isUrgent({ state: "error" }), true)
  assert.equal(M.isUrgent({ state: "stopped" }), false)
  assert.equal(M.isUrgent(null), false)
})

test("percent clamps", () => {
  assert.equal(M.percent(50, 100), 50)
  assert.equal(M.percent(500, 100), 100)
  assert.equal(M.percent(5, 0), 0)
})

test("formatBytes", () => {
  assert.equal(M.formatBytes(0), "0 B")
  assert.equal(M.formatBytes(1536), "1.5 KiB")
  assert.equal(M.formatBytes(16106127360, 0), "15 GiB")
  assert.equal(M.formatBytes(1536, 1, (n) => String(n).replace(".", ",")), "1,5 KiB")
})

test("shortenHome", () => {
  assert.equal(M.shortenHome("/home/me/GoogleDrive", "/home/me"), "~/GoogleDrive")
  assert.equal(M.shortenHome("/home/me", "/home/me"), "~")
  assert.equal(M.shortenHome("/home/meow/x", "/home/me"), "/home/meow/x")
})

test("shellQuote and neutralizeMarkup", () => {
  assert.equal(M.shellQuote("a'b"), "'a'\\''b'")
  assert.equal(M.neutralizeMarkup("<b>hi</b>   there", 8), "b hi /b…")
})

// ---- i18n catalogs (the widget's i18n/*.json and the CLI's i18n/cli/*.json) ----
import { readdirSync } from "node:fs"
const root = new URL("../../", import.meta.url)
const read = rel => readFileSync(new URL(rel, root), "utf8")
const keysOf = rel => Object.keys(JSON.parse(read(rel)))

for (const dir of ["i18n/", "i18n/cli/"]) {
  test(`${dir} catalogs all carry the same keys as en.json`, () => {
    const en = keysOf(dir + "en.json").sort()
    for (const f of readdirSync(new URL(dir, root)).filter(f => f.endsWith(".json"))) {
      assert.deepEqual(keysOf(dir + f).sort(), en, dir + f)
    }
  })
}

test("every widget string the QML asks for exists in i18n/en.json", () => {
  const en = new Set(keysOf("i18n/en.json"))
  const src = ["Panel.qml", "DriveView.qml"].map(read).join("\n")
  const used = [...src.matchAll(/\bt\("([^"]+)"\)/g)].map(m => m[1])
  assert.ok(used.length > 20)
  for (const k of used) assert.ok(en.has(k), k)
  // stateText() builds "state.<x>" keys.
  for (const s of ["mounted", "starting", "stopped", "error", "unconfigured", "unknown"]) assert.ok(en.has("state." + s), s)
})

test("every CLI message key the shell scripts use exists in i18n/cli/en.json", () => {
  const en = new Set(keysOf("i18n/cli/en.json"))
  const src = ["bin/omarchy-gdrive", "lib/common.sh", "lib/gdrive.sh"].map(read).join("\n")
  const used = [...src.matchAll(/\$\(t "?([a-zA-Z]+\.[a-zA-Z.]+)"?[ )]/g)].map(m => m[1])
  assert.ok(used.length > 50)
  for (const k of used) assert.ok(en.has(k), k)
})
