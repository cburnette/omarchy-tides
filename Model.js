// Pure tide logic for the tide clock overlay. No QML, so it runs under node
// for the tests in tests/.
//
// Data source: Open-Meteo's marine API, hourly-ish (15 minute) modelled sea
// level including tides. All times are handled as real epoch milliseconds
// (the API is asked for GMT) and shown in the viewer's local time.

var MAX_RESPONSE_POINTS = 2000
var MIN_TIDE_RANGE_M = 0.03
var M_TO_FT = 3.28084

function isCoordinatePair(lat, lon) {
  return typeof lat === "number" && typeof lon === "number" && isFinite(lat) && isFinite(lon)
    && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
}

function cleanName(value) {
  var s = typeof value === "string" ? value : ""
  s = s.replace(/[\u0000-\u001f\u007f]/g, "").replace(/^\s+|\s+$/g, "")
  return s.length > 80 ? s.slice(0, 80) : s
}

// tides.json / weather.json / geo.omarchy.org all share
// {"name", "latitude", "longitude"}; tides.json may also carry "units".
function parseLocation(raw) {
  var out = { name: "", latitude: null, longitude: null, units: "" }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object" || Array.isArray(data)) return out
    var lat = parseFloat(data.latitude)
    var lon = parseFloat(data.longitude)
    out.name = cleanName(data.name)
    if (isCoordinatePair(lat, lon)) {
      out.latitude = lat
      out.longitude = lon
    }
    if (data.units === "ft" || data.units === "m") out.units = data.units
  } catch (e) {}
  return out
}

function hasCoordinates(loc) {
  return !!loc && isCoordinatePair(loc.latitude, loc.longitude)
}

// Which location to use: one set for tides, then the weather widget's, then
// where geo.omarchy.org places this network.
function effectiveLocation(tides, weather, detected) {
  if (hasCoordinates(tides)) return { name: tides.name, latitude: tides.latitude, longitude: tides.longitude, source: "tides" }
  if (hasCoordinates(weather)) return { name: weather.name, latitude: weather.latitude, longitude: weather.longitude, source: "weather" }
  if (hasCoordinates(detected)) return { name: detected.name, latitude: detected.latitude, longitude: detected.longitude, source: "detected" }
  return null
}

function serializeSettings(location, units) {
  var out = {}
  if (hasCoordinates(location)) {
    out.name = cleanName(location.name)
    out.latitude = location.latitude
    out.longitude = location.longitude
  }
  if (units === "ft" || units === "m") out.units = units
  return JSON.stringify(out, null, 2) + "\n"
}

function marineUrl(lat, lon) {
  if (!isCoordinatePair(lat, lon)) return ""
  return "https://marine-api.open-meteo.com/v1/marine?latitude=" + lat.toFixed(4)
    + "&longitude=" + lon.toFixed(4)
    + "&minutely_15=sea_level_height_msl&past_days=1&forecast_days=3&timezone=GMT"
}

function geocodeUrl(query) {
  var q = String(query || "").slice(0, 80)
  return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(q) + "&count=5&language=en&format=json"
}

// "2026-11-24T00:15" in GMT → epoch ms, or NaN.
function parseGmtTime(s) {
  var m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(String(s || ""))
  if (!m) return NaN
  return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])
}

// Marine response → { ok, reason, points: [{t, h}], gridLatitude, gridLongitude }.
// reason is "network", "inland" (no sea level at that point) or "".
function parseMarine(raw) {
  var fail = function(reason) { return { ok: false, reason: reason, points: [], gridLatitude: null, gridLongitude: null } }
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return fail("network") }
  if (!data || typeof data !== "object" || data.error) return fail("network")
  var block = data.minutely_15
  if (!block || !Array.isArray(block.time) || !Array.isArray(block.sea_level_height_msl)) return fail("network")

  var n = Math.min(block.time.length, block.sea_level_height_msl.length, MAX_RESPONSE_POINTS)
  var points = []
  for (var i = 0; i < n; i++) {
    var t = parseGmtTime(block.time[i])
    var h = block.sea_level_height_msl[i]
    if (!isFinite(t) || typeof h !== "number" || !isFinite(h) || Math.abs(h) > 50) continue
    points.push({ t: t, h: h })
  }
  if (points.length < 8) return fail("inland")

  var gLat = parseFloat(data.latitude)
  var gLon = parseFloat(data.longitude)
  return {
    ok: true,
    reason: "",
    points: points,
    gridLatitude: isCoordinatePair(gLat, gLon) ? gLat : null,
    gridLongitude: isCoordinatePair(gLat, gLon) ? gLon : null
  }
}

// Refine an extreme between three equally spaced samples with a parabola.
function refineExtreme(a, b, c) {
  var denom = a.h - 2 * b.h + c.h
  if (denom === 0) return { t: b.t, h: b.h }
  var offset = 0.5 * (a.h - c.h) / denom
  if (offset > 1) offset = 1
  if (offset < -1) offset = -1
  var step = (c.t - a.t) / 2
  return { t: b.t + offset * step, h: b.h - 0.25 * (a.h - c.h) * offset }
}

// Highs and lows in time order, alternating, ignoring wobbles smaller than
// MIN_TIDE_RANGE_M.
function findExtremes(points) {
  var raw = []
  for (var i = 1; i < points.length - 1; i++) {
    var p = points[i - 1], q = points[i], r = points[i + 1]
    var type = ""
    if (q.h >= p.h && q.h > r.h) type = "high"
    else if (q.h <= p.h && q.h < r.h) type = "low"
    if (!type) continue
    var x = refineExtreme(p, q, r)
    raw.push({ t: x.t, h: x.h, type: type })
  }

  var changed = true
  while (changed) {
    changed = false
    // Same type twice in a row: keep the more extreme one.
    var alt = []
    for (var j = 0; j < raw.length; j++) {
      var e = raw[j]
      var last = alt[alt.length - 1]
      if (last && last.type === e.type) {
        if ((e.type === "high" && e.h > last.h) || (e.type === "low" && e.h < last.h)) alt[alt.length - 1] = e
        changed = true
      } else {
        alt.push(e)
      }
    }
    // Drop the smallest high/low pair that is just noise.
    var smallest = -1, smallestRange = MIN_TIDE_RANGE_M
    for (var k = 0; k < alt.length - 1; k++) {
      var range = Math.abs(alt[k].h - alt[k + 1].h)
      if (range < smallestRange) { smallestRange = range; smallest = k }
    }
    if (smallest >= 0) {
      alt.splice(smallest, 2)
      changed = true
    }
    raw = alt
  }
  return raw
}

function levelAt(points, t) {
  if (!points.length) return null
  if (t <= points[0].t) return points[0].h
  for (var i = 1; i < points.length; i++) {
    if (points[i].t >= t) {
      var a = points[i - 1], b = points[i]
      var f = (t - a.t) / (b.t - a.t)
      return a.h + (b.h - a.h) * f
    }
  }
  return points[points.length - 1].h
}

// Where the tide is right now. angle is clockwise degrees from the top of a
// tide clock: 0 = high, 90 = halfway falling, 180 = low, 270 = halfway rising.
function tideState(points, extremes, now) {
  var prev = null, next = null
  for (var i = 0; i < extremes.length; i++) {
    if (extremes[i].t <= now) prev = extremes[i]
    else { next = extremes[i]; break }
  }
  var level = levelAt(points, now)
  if (!prev || !next || level === null) return { ok: false, level: level, rising: false, prev: prev, next: next, fraction: 0, angle: 0 }

  var fraction = (now - prev.t) / (next.t - prev.t)
  if (fraction < 0) fraction = 0
  if (fraction > 1) fraction = 1
  var rising = prev.type === "low"
  return {
    ok: true,
    level: level,
    rising: rising,
    prev: prev,
    next: next,
    fraction: fraction,
    angle: rising ? 180 + 180 * fraction : 180 * fraction
  }
}

function upcoming(extremes, now, count) {
  var out = []
  for (var i = 0; i < extremes.length && out.length < count; i++)
    if (extremes[i].t > now) out.push(extremes[i])
  return out
}

function convertHeight(meters, units) {
  return units === "ft" ? meters * M_TO_FT : meters
}

function defaultUnits(localeName) {
  var l = String(localeName || "")
  return /[-_](US|LR|MM)\b/.test(l) ? "ft" : "m"
}

function durationParts(ms) {
  var minutes = Math.max(0, Math.round(ms / 60000))
  return { hours: Math.floor(minutes / 60), minutes: minutes % 60 }
}

// Distance in km between the asked-for point and the sea grid cell used.
function distanceKm(lat1, lon1, lat2, lon2) {
  if (!isCoordinatePair(lat1, lon1) || !isCoordinatePair(lat2, lon2)) return 0
  var rad = Math.PI / 180
  var dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data && data.results
    if (!Array.isArray(results)) return []
    var out = []
    for (var i = 0; i < results.length && out.length < 5; i++) {
      var r = results[i]
      if (!r) continue
      var lat = parseFloat(r.latitude), lon = parseFloat(r.longitude)
      var name = cleanName(r.name)
      if (!name || !isCoordinatePair(lat, lon)) continue
      var region = [cleanName(r.admin1), cleanName(r.country)].filter(function(part) { return !!part }).join(", ")
      out.push({ name: name, description: region, latitude: lat, longitude: lon })
    }
    return out
  } catch (e) {
    return []
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocation: parseLocation,
    hasCoordinates: hasCoordinates,
    effectiveLocation: effectiveLocation,
    serializeSettings: serializeSettings,
    marineUrl: marineUrl,
    geocodeUrl: geocodeUrl,
    parseGmtTime: parseGmtTime,
    parseMarine: parseMarine,
    findExtremes: findExtremes,
    levelAt: levelAt,
    tideState: tideState,
    upcoming: upcoming,
    convertHeight: convertHeight,
    defaultUnits: defaultUnits,
    durationParts: durationParts,
    distanceKm: distanceKm,
    parseGeocodingResults: parseGeocodingResults
  }
}
