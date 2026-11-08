// Run with: node --test Model.test.js
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

// Model.js is a QML JavaScript library (".pragma library"); evaluate it in a sandbox.
const src = readFileSync(new URL("./Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
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
