// Run: node --test ~/.config/omarchy/plugins/tides/tests/
const test = require("node:test")
const assert = require("node:assert")
const path = require("node:path")
const M = require(path.join(__dirname, "..", "Model.js"))

const PERIOD = 12.42 * 3600e3 // semidiurnal tide
const T0 = Date.UTC(2026, 10, 24, 0, 0)

function synthetic(hours, amp, noise) {
  const time = [], level = []
  for (let i = 0; i <= hours * 4; i++) {
    const t = T0 + i * 15 * 60e3
    const d = new Date(t).toISOString().slice(0, 16)
    time.push(d)
    level.push(amp * Math.cos(2 * Math.PI * (t - T0) / PERIOD) + (noise ? 0.005 * Math.sin(i * 1.7) : 0))
  }
  return JSON.stringify({ latitude: 40.6, longitude: -73.9, minutely_15: { time, sea_level_height_msl: level } })
}

test("finds alternating highs and lows at the right times", () => {
  const r = M.parseMarine(synthetic(48, 1.0, false))
  assert.ok(r.ok)
  const ex = M.findExtremes(r.points)
  for (let i = 1; i < ex.length; i++) assert.notStrictEqual(ex[i].type, ex[i - 1].type)
  const firstLow = ex.find(e => e.type === "low")
  assert.ok(Math.abs(firstLow.t - (T0 + PERIOD / 2)) < 10 * 60e3, "low within 10 minutes")
  assert.ok(Math.abs(firstLow.h + 1.0) < 0.01)
})

test("small wobbles are not reported as tides", () => {
  const ex = M.findExtremes(M.parseMarine(synthetic(48, 1.0, true)).points)
  for (let i = 1; i < ex.length; i++) assert.ok(Math.abs(ex[i].h - ex[i - 1].h) > 1)
})

test("clock angle: 0 at high, 90 falling, 180 low, 270 rising", () => {
  const r = M.parseMarine(synthetic(48, 1.0, false))
  const ex = M.findExtremes(r.points)
  const hi = ex.find(e => e.type === "high")
  const lo = ex.find(e => e.type === "low" && e.t > hi.t)
  const mid = (hi.t + lo.t) / 2
  const s = M.tideState(r.points, ex, mid)
  assert.ok(s.ok && !s.rising)
  assert.ok(Math.abs(s.angle - 90) < 2)
  const hi2 = ex.find(e => e.type === "high" && e.t > lo.t)
  const s2 = M.tideState(r.points, ex, (lo.t + hi2.t) / 2)
  assert.ok(s2.rising && Math.abs(s2.angle - 270) < 2)
})

test("inland point (all nulls) is reported as inland", () => {
  const time = Array.from({ length: 50 }, (_, i) => new Date(T0 + i * 9e5).toISOString().slice(0, 16))
  const r = M.parseMarine(JSON.stringify({ minutely_15: { time, sea_level_height_msl: time.map(() => null) } }))
  assert.strictEqual(r.reason, "inland")
})

test("garbage and API errors are network failures", () => {
  assert.strictEqual(M.parseMarine("<html>").reason, "network")
  assert.strictEqual(M.parseMarine('{"error":true,"reason":"x"}').reason, "network")
})

test("location parsing validates and strips markup-ish control chars", () => {
  const l = M.parseLocation('{"name":"<img src=x>\\u0007Brooklyn","latitude":"40.6","longitude":-73.9,"units":"ft"}')
  assert.strictEqual(l.latitude, 40.6)
  assert.strictEqual(l.units, "ft")
  assert.ok(!/\u0007/.test(l.name))
  assert.strictEqual(M.parseLocation('{"latitude":200,"longitude":0}').latitude, null)
  assert.strictEqual(M.parseLocation("not json").name, "")
})

test("location priority: tides, then weather, then detected", () => {
  const a = { name: "A", latitude: 1, longitude: 1 }, b = { name: "B", latitude: 2, longitude: 2 }, c = { name: "C", latitude: 3, longitude: 3 }
  const none = M.parseLocation("")
  assert.strictEqual(M.effectiveLocation(a, b, c).name, "A")
  assert.strictEqual(M.effectiveLocation(none, b, c).source, "weather")
  assert.strictEqual(M.effectiveLocation(none, none, c).source, "detected")
  assert.strictEqual(M.effectiveLocation(none, none, none), null)
})

test("settings round-trip", () => {
  const s = M.serializeSettings({ name: "Malibu", latitude: 34.03, longitude: -118.78 }, "ft")
  const l = M.parseLocation(s)
  assert.deepStrictEqual([l.name, l.latitude, l.longitude, l.units], ["Malibu", 34.03, -118.78, "ft"])
})

test("units default from locale", () => {
  assert.strictEqual(M.defaultUnits("en-US"), "ft")
  assert.strictEqual(M.defaultUnits("en-GB"), "m")
})
