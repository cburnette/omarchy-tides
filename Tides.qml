import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Tide clock overlay. Toggled with `omarchy-shell shell toggle cburnette.tides`
// (Super + Alt + T). Network use: one Open-Meteo marine request when opened
// and the data is older than 30 minutes or the location changed, plus
// geo.omarchy.org only when no location is configured anywhere. Nothing runs
// in the background while it is closed.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string settingsDir: home + "/.local/state/omarchy/settings"
  readonly property string settingsPath: settingsDir + "/tides.json"

  // Locations, in priority order (see Model.effectiveLocation).
  property var tidesSettings: Model.parseLocation("")
  property var weatherSettings: Model.parseLocation("")
  property var detectedLocation: Model.parseLocation("")
  property bool detecting: false
  readonly property var location: Model.effectiveLocation(tidesSettings, weatherSettings, detectedLocation)
  readonly property string locationKey: location ? location.latitude.toFixed(4) + "," + location.longitude.toFixed(4) : ""

  readonly property string units: tidesSettings.units || Model.defaultUnits(Commons.I18n.formatLocale)

  // Tide data.
  property var points: []
  property var extremes: []
  property string status: "idle" // idle | loading | ok | inland | network
  property string fetchedKey: ""
  property double fetchedAt: 0
  property real gridDistanceKm: 0
  property double now: Date.now()
  readonly property var tide: status === "ok" ? Model.tideState(points, extremes, now) : null
  readonly property var nextTides: status === "ok" ? Model.upcoming(extremes, now, 4) : []

  // Location editing.
  property bool editing: false
  property var suggestions: []
  property int suggestionIndex: 0
  property string geocodeActive: ""
  property string geocodePending: ""
  property var pendingSave: null

  // Look.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.menuFamily
  readonly property int pad: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.lg
  property int cardWidth: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ── Shell entry points ────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.editing = false
    root.now = Date.now()
    tidesFile.reload()
    weatherFile.reload()
    root.ensureLocation()
    root.refreshIfStale(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    root.editing = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "cburnette.tides")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ── Location ──────────────────────────────────────────────────────────
  function ensureLocation() {
    if (root.location || root.detecting) return
    root.detecting = true
    geoProc.running = true
  }

  onLocationKeyChanged: if (root.opened) root.refreshIfStale(false)

  function saveSettings(loc, units) {
    root.pendingSave = Model.serializeSettings(loc, units)
    mkdirProc.running = true
  }

  function chooseSuggestion(index) {
    var s = root.suggestions[index]
    if (!s) return
    root.saveSettings(s, root.tidesSettings.units)
    root.tidesSettings = Model.parseLocation(Model.serializeSettings(s, root.tidesSettings.units))
    root.stopEditing()
  }

  function useAutoLocation() {
    root.saveSettings(null, root.tidesSettings.units)
    root.tidesSettings = Model.parseLocation(Model.serializeSettings(null, root.tidesSettings.units))
    root.stopEditing()
    root.ensureLocation()
  }

  function toggleUnits() {
    var next = root.units === "ft" ? "m" : "ft"
    var loc = Model.hasCoordinates(root.tidesSettings) ? root.tidesSettings : null
    root.saveSettings(loc, next)
    var updated = Model.parseLocation(Model.serializeSettings(loc, next))
    root.tidesSettings = updated
  }

  function startEditing() {
    root.editing = true
    root.suggestions = []
    root.suggestionIndex = -1
    searchField.text = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function stopEditing() {
    root.editing = false
    geocodeDebounce.stop()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function requestGeocode() {
    var q = searchField.text.trim()
    if (q.length < 2) { root.suggestions = []; root.suggestionIndex = -1; return }
    root.geocodePending = q
    if (!geocodeProc.running) root.startGeocode()
  }

  function startGeocode() {
    root.geocodeActive = root.geocodePending
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5", "--max-filesize", "200000", Model.geocodeUrl(root.geocodeActive)]
    geocodeProc.running = true
  }

  // ── Tide data ─────────────────────────────────────────────────────────
  function refreshIfStale(force) {
    if (!root.location) return
    var fresh = root.fetchedKey === root.locationKey && (Date.now() - root.fetchedAt) < 30 * 60 * 1000
    if (!force && fresh && root.status === "ok") return
    if (marineProc.running) return
    root.status = "loading"
    root.fetchedKey = root.locationKey
    marineProc.command = ["curl", "-fsS", "--max-time", "10", "--max-filesize", "1000000",
      Model.marineUrl(root.location.latitude, root.location.longitude)]
    marineProc.running = true
  }

  function applyMarine(raw) {
    var r = Model.parseMarine(raw)
    if (!r.ok) {
      root.status = r.reason
      root.points = []
      root.extremes = []
      return
    }
    root.points = r.points
    root.extremes = Model.findExtremes(r.points)
    root.gridDistanceKm = root.location
      ? Model.distanceKm(root.location.latitude, root.location.longitude, r.gridLatitude, r.gridLongitude) : 0
    root.fetchedAt = Date.now()
    root.now = Date.now()
    root.status = root.extremes.length >= 2 ? "ok" : "inland"
  }

  // ── Formatting ────────────────────────────────────────────────────────
  function fmtHeight(meters) {
    return Commons.I18n.formatNumber(Model.convertHeight(meters, root.units), root.units === "ft" ? 1 : 2) + " " + root.units
  }

  function fmtTime(t) {
    return new Date(t).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function fmtDay(t) {
    var d = new Date(t), today = new Date(root.now)
    var tomorrow = new Date(root.now); tomorrow.setDate(tomorrow.getDate() + 1)
    if (d.toDateString() === today.toDateString()) return strings.t("today")
    if (d.toDateString() === tomorrow.toDateString()) return strings.t("tomorrow")
    return d.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "ddd")
  }

  function fmtDuration(ms) {
    var p = Model.durationParts(ms)
    if (p.hours > 0) return strings.t("duration.hm").arg(Commons.I18n.formatNumber(p.hours)).arg(Commons.I18n.formatNumber(p.minutes))
    return strings.t("duration.m").arg(Commons.I18n.formatNumber(p.minutes))
  }

  readonly property string statusMessage: {
    if (root.status === "inland") return strings.t("inland")
    if (root.status === "network") return strings.t("network")
    if (!root.location) return root.detecting ? strings.t("locating") : strings.t("noLocation")
    return strings.t("loading")
  }

  // ── Processes and files ───────────────────────────────────────────────
  FileView {
    id: tidesFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.tidesSettings = Model.parseLocation(text())
    onLoadFailed: root.tidesSettings = Model.parseLocation("")
  }

  FileView {
    id: weatherFile
    path: root.settingsDir + "/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.weatherSettings = Model.parseLocation(text())
    onLoadFailed: root.weatherSettings = Model.parseLocation("")
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.settingsDir]
    onExited: function(exitCode) {
      if (exitCode === 0 && root.pendingSave !== null) tidesFile.setText(root.pendingSave)
      root.pendingSave = null
    }
  }

  Process {
    id: geoProc
    command: ["curl", "-fsS", "--max-time", "4", "--max-filesize", "20000", "https://geo.omarchy.org/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.detectedLocation = Model.parseLocation(text)
    }
    onExited: root.detecting = false
  }

  Process {
    id: marineProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMarine(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.status === "loading") root.status = "network"
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.suggestions = root.editing ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = root.suggestions.length > 0 ? 0 : -1
        if (root.geocodePending !== root.geocodeActive) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  // Keep the hand moving while it's open; refetch if it was left open long.
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: {
      root.now = Date.now()
      root.refreshIfStale(false)
    }
  }

  onTideChanged: { dial.requestPaint(); curve.requestPaint() }
  onUnitsChanged: curve.requestPaint()

  // ── UI ────────────────────────────────────────────────────────────────
  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-tides"

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.pad

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.editing) return
          if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
          else if (event.key === Qt.Key_L) { root.startEditing(); event.accepted = true }
          else if (event.key === Qt.Key_U) { root.toggleUnits(); event.accepted = true }
          else if (event.key === Qt.Key_R) { root.ensureLocation(); root.refreshIfStale(true); event.accepted = true }
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.gap

        // Header: title and location (click to change).
        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, locationColumn.implicitHeight)

          PlainLabel {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("title")
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Column {
            id: locationColumn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - titleText.implicitWidth - root.gap

            PlainLabel {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              text: root.location ? (root.location.name || (Commons.I18n.formatNumber(root.location.latitude, 3) + ", " + Commons.I18n.formatNumber(root.location.longitude, 3))) : "—"
              font.pixelSize: Style.font.title
              color: locationMouse.containsMouse ? root.selectedText : root.foreground
            }
            PlainLabel {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              visible: !!root.location
              text: root.location ? strings.t("source." + root.location.source) : ""
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }
          }

          MouseArea {
            id: locationMouse
            anchors.fill: locationColumn
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.editing ? root.stopEditing() : root.startEditing()
          }
        }

        // ── Location search ───────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: root.editing

          TextField {
            id: searchField
            width: parent.width
            placeholderText: strings.t("searchPlaceholder")
            font.pixelSize: Style.font.title
            onTextChanged: geocodeDebounce.restart()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.stopEditing(); event.accepted = true }
              else if (event.key === Qt.Key_Down) {
                root.suggestionIndex = Math.min(root.suggestionIndex + 1, root.suggestions.length - 1); event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.suggestionIndex = Math.max(root.suggestionIndex - 1, -1); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.suggestionIndex >= 0) root.chooseSuggestion(root.suggestionIndex)
                else if (searchField.text.trim() === "") root.useAutoLocation()
                event.accepted = true
              }
            }
          }

          Repeater {
            model: root.suggestions
            delegate: Rectangle {
              required property var modelData
              required property int index
              width: parent.width
              height: Style.spacing.popupRowHeight + Style.spacing.sm
              radius: Style.cornerRadius
              color: index === root.suggestionIndex ? root.selectedBackground : "transparent"

              PlainLabel {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.description ? modelData.name + " · " + modelData.description : modelData.name
                color: index === root.suggestionIndex ? root.selectedText : root.foreground
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: root.suggestionIndex = index
                onClicked: root.chooseSuggestion(index)
              }
            }
          }

          PlainLabel {
            visible: searchField.text.trim().length >= 2 && root.suggestions.length === 0 && !geocodeProc.running
            text: strings.t("noMatches")
            opacity: 0.6
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.popupRowHeight + Style.spacing.sm
            radius: Style.cornerRadius
            color: autoMouse.containsMouse ? root.selectedBackground : "transparent"
            PlainLabel {
              anchors.left: parent.left
              anchors.margins: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: "󰆤  " + strings.t("autoDetect")
              color: autoMouse.containsMouse ? root.selectedText : root.foreground
              opacity: autoMouse.containsMouse ? 1 : 0.75
            }
            MouseArea {
              id: autoMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.useAutoLocation()
            }
          }
        }

        // ── Clock ─────────────────────────────────────────────────────
        Item {
          width: parent.width
          height: dial.height
          visible: !root.editing

          Canvas {
            id: dial
            width: Math.min(parent.width, Style.space(240))
            height: width
            anchors.horizontalCenter: parent.horizontalCenter
            antialiasing: true
            onPaint: {
              var ctx = getContext("2d")
              var w = width, c = w / 2, r = w / 2 - Style.space(4)
              ctx.reset()
              ctx.lineWidth = Math.max(1, Style.space(2))

              // Face.
              ctx.beginPath()
              ctx.arc(c, c, r, 0, Math.PI * 2)
              ctx.strokeStyle = root.border
              ctx.stroke()

              // Hour ticks: 5 4 3 2 1 down the falling side, then up the rising side.
              ctx.fillStyle = root.foreground
              ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
              ctx.textAlign = "center"
              ctx.textBaseline = "middle"
              for (var i = 1; i < 6; i++) {
                for (var side = 0; side < 2; side++) {
                  var deg = side === 0 ? i * 30 : 180 + i * 30
                  var a = (deg - 90) * Math.PI / 180
                  ctx.beginPath()
                  ctx.moveTo(c + Math.cos(a) * (r - Style.space(6)), c + Math.sin(a) * (r - Style.space(6)))
                  ctx.lineTo(c + Math.cos(a) * r, c + Math.sin(a) * r)
                  ctx.strokeStyle = root.border
                  ctx.stroke()
                  ctx.globalAlpha = 0.55
                  ctx.fillText(String(6 - i), c + Math.cos(a) * (r - Style.space(16)), c + Math.sin(a) * (r - Style.space(16)))
                  ctx.globalAlpha = 1
                }
              }

              // HIGH / LOW and the sides.
              ctx.font = "bold " + Style.font.body + "px \"" + root.fontFamily + "\""
              ctx.fillText(strings.t("highCaps"), c, c - r + Style.space(18))
              ctx.fillText(strings.t("lowCaps"), c, c + r - Style.space(18))
              ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
              ctx.globalAlpha = 0.6
              ctx.fillText(strings.t("falling"), c + r * 0.45, c)
              ctx.fillText(strings.t("rising"), c - r * 0.45, c)
              ctx.globalAlpha = 1

              // Hand.
              var st = root.tide
              if (st && st.ok) {
                var ha = (st.angle - 90) * Math.PI / 180
                ctx.beginPath()
                ctx.moveTo(c, c)
                ctx.lineTo(c + Math.cos(ha) * (r - Style.space(28)), c + Math.sin(ha) * (r - Style.space(28)))
                ctx.lineWidth = Math.max(2, Style.space(4))
                ctx.lineCap = "round"
                ctx.strokeStyle = root.accent
                ctx.stroke()
              }
              ctx.beginPath()
              ctx.arc(c, c, Style.space(5), 0, Math.PI * 2)
              ctx.fillStyle = root.accent
              ctx.fill()
            }
          }
        }

        // Status line under the clock.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: !root.editing

          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
            font.pixelSize: Style.font.heading
            text: root.tide && root.tide.ok
              ? (root.tide.rising ? strings.t("untilHigh") : strings.t("untilLow")).arg(root.fmtDuration(root.tide.next.t - root.now))
              : root.statusMessage
          }
          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: !!(root.tide && root.tide.ok)
            opacity: 0.7
            text: root.tide && root.tide.ok
              ? (root.tide.rising ? strings.t("rising") : strings.t("falling")) + " · " + root.fmtHeight(root.tide.level)
              : ""
          }
        }

        // ── 24 hour curve ─────────────────────────────────────────────
        Canvas {
          id: curve
          width: parent.width
          height: Style.space(70)
          visible: !root.editing && root.status === "ok"
          antialiasing: true
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var pts = root.points
            if (!pts.length) return
            var t0 = root.now - 6 * 3600e3, t1 = root.now + 18 * 3600e3
            var lo = Infinity, hi = -Infinity
            for (var i = 0; i < pts.length; i++) {
              if (pts[i].t < t0 || pts[i].t > t1) continue
              lo = Math.min(lo, pts[i].h); hi = Math.max(hi, pts[i].h)
            }
            if (!isFinite(lo) || hi - lo < 0.01) return
            var w = width, h = height, m = Style.space(6)
            function X(t) { return (t - t0) / (t1 - t0) * w }
            function Y(v) { return m + (1 - (v - lo) / (hi - lo)) * (h - 2 * m) }

            ctx.beginPath()
            var started = false
            for (var j = 0; j < pts.length; j++) {
              if (pts[j].t < t0 || pts[j].t > t1) continue
              if (!started) { ctx.moveTo(X(pts[j].t), Y(pts[j].h)); started = true }
              else ctx.lineTo(X(pts[j].t), Y(pts[j].h))
            }
            ctx.lineWidth = Math.max(1, Style.space(2))
            ctx.strokeStyle = root.accent
            ctx.stroke()
            ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath()
            ctx.globalAlpha = 0.12
            ctx.fillStyle = root.accent
            ctx.fill()
            ctx.globalAlpha = 1

            // Highs and lows.
            var ex = root.extremes
            for (var k = 0; k < ex.length; k++) {
              if (ex[k].t < t0 || ex[k].t > t1) continue
              ctx.beginPath()
              ctx.arc(X(ex[k].t), Y(ex[k].h), Style.space(3), 0, Math.PI * 2)
              ctx.fillStyle = root.foreground
              ctx.fill()
            }

            // Now.
            ctx.beginPath()
            ctx.moveTo(X(root.now), 0)
            ctx.lineTo(X(root.now), h)
            ctx.lineWidth = 1
            ctx.strokeStyle = root.foreground
            ctx.globalAlpha = 0.5
            ctx.stroke()
            ctx.globalAlpha = 1
          }
        }

        // ── Upcoming tides ────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: !root.editing && root.nextTides.length > 0

          Repeater {
            model: root.nextTides
            delegate: Item {
              required property var modelData
              width: parent.width
              height: rowType.implicitHeight + Style.spacing.xs

              PlainLabel {
                id: rowType
                anchors.left: parent.left
                width: parent.width * 0.3
                text: (modelData.type === "high" ? "▲ " : "▼ ") + strings.t(modelData.type)
                font.bold: true
              }
              PlainLabel {
                anchors.left: rowType.right
                width: parent.width * 0.45
                text: root.fmtDay(modelData.t) + "  " + root.fmtTime(modelData.t)
              }
              PlainLabel {
                anchors.right: parent.right
                width: parent.width * 0.25
                horizontalAlignment: Text.AlignRight
                text: root.fmtHeight(modelData.h)
                opacity: 0.75
              }
            }
          }
        }

        // ── Footer ────────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.spacing.xxs

          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: !root.editing && root.status === "ok" && root.gridDistanceKm >= 5
            font.pixelSize: Style.font.caption
            opacity: 0.55
            text: strings.t("gridNote").arg(Commons.I18n.formatNumber(Math.round(root.gridDistanceKm)))
          }
          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: Style.font.caption
            opacity: 0.55
            text: root.editing ? strings.t("editHints") : strings.t("hints")
          }
          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: !root.editing
            font.pixelSize: Style.font.caption
            opacity: 0.4
            text: strings.t("disclaimer")
          }
        }
      }
    }
  }
}
