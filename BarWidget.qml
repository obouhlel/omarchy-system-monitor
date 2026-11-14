import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// CPU, RAM, GPU and VRAM in one bar reading.
//
// Keeps the numbers permanently in view — VRAM above all, since a full card is
// what stops the shell from allocating its EGL surfaces and takes the bar down
// with it.
//
// Left click opens btop, right click drops the RAM caches (asks for sudo),
// middle click runs the bundled bin/vram-clean (NVIDIA only). Readings come
// from /proc, nvidia-smi on NVIDIA and sysfs on AMD.
BarWidget {
  id: root
  moduleName: "obouhlel.sysmon"

  readonly property bool showGpu: setting("showGpu", true)
  readonly property int warnThreshold: setting("warnThreshold", 75)
  readonly property int refreshSec: setting("refreshIntervalSec", 2)

  property real cpuPercent: 0
  property real memPercent: 0
  property string memUsedLabel: ""

  // Stays false until nvidia-smi actually answers, so a machine without an
  // NVIDIA card simply shows CPU and RAM instead of two dead readings.
  property bool gpuAvailable: false
  property real gpuPercent: 0
  property real gpuMemPercent: 0
  property string gpuMemUsedLabel: ""
  property int gpuTemp: -1
  property real gpuPower: -1
  property string gpuName: ""
  property int cpuTemp: -1
  property string swapLabel: ""
  property bool hoverOpen: false
  // bin/vram-clean ships with the plugin but only works on NVIDIA; the middle
  // click and its hint are dropped where nvidia-smi is missing.
  property bool hasVramClean: false
  readonly property string vramCleanPath: Qt.resolvedUrl("bin/vram-clean").toString().replace(/^file:\/\//, "")

  property real _prevTotal: 0
  property real _prevIdle: 0

  readonly property bool gpuShown: root.showGpu && root.gpuAvailable

  // The bar lays widgets out by implicit size; BarWidget is a bare Item, so
  // without this the widget claims zero width and never paints.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function _applyStat(text) {
    var line = String(text || "").split("\n")[0]
    if (line.indexOf("cpu ") !== 0) return
    var f = line.trim().split(/\s+/)
    var total = 0
    for (var i = 1; i < f.length; i++) total += Number(f[i]) || 0
    // fields: user nice system idle iowait irq softirq ...
    var idle = (Number(f[4]) || 0) + (Number(f[5]) || 0)

    if (root._prevTotal > 0) {
      var dt = total - root._prevTotal
      var di = idle - root._prevIdle
      if (dt > 0) root.cpuPercent = Math.max(0, Math.min(100, (1 - di / dt) * 100))
    }
    root._prevTotal = total
    root._prevIdle = idle
  }

  function _applyMem(text) {
    var lines = String(text || "").split("\n")
    var totalKb = 0, availKb = 0
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(MemTotal|MemAvailable):\s+(\d+)/)
      if (!m) continue
      if (m[1] === "MemTotal") totalKb = Number(m[2])
      else availKb = Number(m[2])
    }
    var sw = String(text || "").match(/SwapTotal:\s+(\d+)[\s\S]*SwapFree:\s+(\d+)/)
    if (sw && Number(sw[1]) > 0)
      root.swapLabel = ((Number(sw[1]) - Number(sw[2])) / 1048576).toFixed(1) + " / " + (Number(sw[1]) / 1048576).toFixed(0) + " GB"
    if (totalKb <= 0) return
    var usedKb = totalKb - availKb
    root.memPercent = Math.max(0, Math.min(100, usedKb / totalKb * 100))
    root.memUsedLabel = (usedKb / 1048576).toFixed(1) + " / " + (totalKb / 1048576).toFixed(0) + " GB"
  }

  // nvidia-smi answers "11, 5790, 8192" — utilisation %, then MiB used and total.
  function _applyGpu(text) {
    var line = String(text || "").replace(/^\s+|\s+$/g, "").split("\n")[0]
    if (!line) return
    var f = line.split(",")
    if (f.length < 3) return

    var util = Number(f[0])
    var usedMib = Number(f[1])
    var totalMib = Number(f[2])
    // A driver mid-reset answers "[N/A]"; keep the last good reading.
    if (isNaN(util) || isNaN(usedMib) || isNaN(totalMib) || totalMib <= 0) return

    root.gpuPercent = Math.max(0, Math.min(100, util))
    root.gpuMemPercent = Math.max(0, Math.min(100, usedMib / totalMib * 100))
    root.gpuMemUsedLabel = (usedMib / 1024).toFixed(1) + " / " + (totalMib / 1024).toFixed(0) + " GB"
    root.gpuAvailable = true
    if (f.length >= 6) {
      var t = Number(f[3]); root.gpuTemp = isNaN(t) ? -1 : t
      var w = Number(f[4]); root.gpuPower = isNaN(w) ? -1 : w
      root.gpuName = String(f.slice(5).join(",")).trim().replace(/^NVIDIA\s+/, "").replace(/^GeForce\s+/, "").slice(0, 40)
    }
  }

  function _applyCpuTemp(text) {
    var v = Number(String(text || "").trim())
    root.cpuTemp = isNaN(v) || v <= 0 ? -1 : Math.round(v / 1000)
  }

  // Each Process stays bound to one command: reassigning `command` on a shared
  // Process drops work silently.
  Process {
    id: statProc
    command: ["cat", "/proc/stat"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._applyStat(text) }
  }

  Process {
    command: ["sh", "-c", "command -v nvidia-smi >/dev/null 2>&1"]
    running: true
    onExited: function (code) { root.hasVramClean = code === 0 }
  }

  // First k10temp / coretemp sensor, in millidegrees.
  Process {
    id: cpuTempProc
    command: ["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); case $n in k10temp|coretemp|zenpower) cat $h/temp1_input; exit;; esac; done"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._applyCpuTemp(text) }
  }

  Process {
    id: memProc
    command: ["cat", "/proc/meminfo"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._applyMem(text) }
  }

  Process {
    id: gpuProc
    // NVIDIA through nvidia-smi; otherwise the first amdgpu card's sysfs
    // counters, printed in the same CSV shape so _applyGpu reads both.
    command: ["sh", "-c",
      "if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,name --format=csv,noheader,nounits 2>/dev/null; then exit 0; fi; "
      + "for c in /sys/class/drm/card*/device; do [ -r $c/gpu_busy_percent ] || continue; "
      + "u=$(cat $c/gpu_busy_percent); vu=$(( $(cat $c/mem_info_vram_used) / 1048576 )); vt=$(( $(cat $c/mem_info_vram_total) / 1048576 )); "
      + "h=$(ls -d $c/hwmon/hwmon* 2>/dev/null | head -1); t=$(( $(cat $h/temp1_input 2>/dev/null || echo 0) / 1000 )); "
      + "p=$(cat $h/power1_input 2>/dev/null || cat $h/power1_average 2>/dev/null || echo 0); p=$(( p / 1000000 )); "
      + "n=$(cat $c/product_name 2>/dev/null); echo \"$u, $vu, $vt, $t, $p, ${n:-AMD Radeon}\"; exit 0; done; exit 1"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._applyGpu(text) }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) { if (code !== 0) root.gpuAvailable = false }
  }

  Timer {
    interval: Math.max(1, root.refreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!statProc.running) statProc.running = true
      if (!memProc.running) memProc.running = true
      if (!cpuTempProc.running) cpuTempProc.running = true
    }
  }

  // nvidia-smi shells out to the driver and costs far more than a /proc read,
  // so it polls at half the rate of CPU and RAM.
  Timer {
    interval: Math.max(1, root.refreshSec) * 2000
    running: root.showGpu
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!gpuProc.running) gpuProc.running = true
  }

  // One entry per reading: short label + a mini horizontal gauge. Exact
  // figures live in the tooltip, the bar only needs to be read at a glance.
  readonly property var metrics: {
    var m = [{ label: "CPU", value: cpuPercent, sub: cpuTemp >= 0 ? cpuTemp + " °C" : "" },
             { label: "RAM", value: memPercent, sub: memUsedLabel }]
    if (gpuShown) {
      var gs = []
      if (gpuTemp >= 0) gs.push(gpuTemp + " °C")
      if (gpuPower >= 0) gs.push(Math.round(gpuPower) + " W")
      m.push({ label: "GPU", value: gpuPercent, sub: gs.join("  ·  ") })
      m.push({ label: "VRAM", value: gpuMemPercent, sub: gpuMemUsedLabel })
    }
    return m
  }

  // Bar text colour below (threshold - 25 %), halfway to urgent from there,
  // urgent from the warning threshold. Both derive from the theme.
  readonly property color midColor: Qt.tint(button.foreground, Qt.alpha(button.activeColor, 0.5))
  function levelColor(v) {
    if (v >= root.warnThreshold) return button.activeColor
    if (v >= Math.max(0, root.warnThreshold - 25)) return root.midColor
    return button.foreground
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: ""
    fixedWidth: content.implicitWidth + button.scaledHorizontalMargin * 2

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(10)

      Repeater {
        model: root.metrics

        Row {
          required property var modelData
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.label
            color: button.foreground
            opacity: 0.7
            font.family: button.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }

          // Pill gauge with the figure inside. The fill is a translucent tint
          // and the figure is always drawn once, in the bar text colour on top,
          // so no glyph is ever split between two colours.
          Item {
            id: gauge
            anchors.verticalCenter: parent.verticalCenter
            width: 46
            height: 16
            readonly property real frac: Math.max(0, Math.min(100, modelData.value)) / 100
            readonly property color tint: root.levelColor(modelData.value)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.alpha(button.foreground, 0.12)
            }

            // The fill is drawn at its true width and cut to the pill's shape
            // by a mask, so 9 % reads as 9 % and the fill never pokes out of
            // the rounded ends (a plain rounded fill can't go narrower than
            // its own height without breaking its shape).
            Item {
              id: fillLayer
              anchors.fill: parent
              visible: false
              layer.enabled: true

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: gauge.width * gauge.frac
                color: Qt.alpha(gauge.tint, 0.45)
                Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
              }
            }

            Item {
              id: pillMask
              anchors.fill: parent
              visible: false
              layer.enabled: true

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: "black"
              }
            }

            MultiEffect {
              anchors.fill: parent
              source: fillLayer
              maskEnabled: true
              maskSource: pillMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1.0
            }

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: Math.round(modelData.value) + "%"
              color: button.foreground
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }
        }
      }
    }

    onPressed: function (b) {
      root.hoverOpen = false
      if (b === Qt.RightButton) Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.ram-clean", "bash", "-c",
        "free -h; echo; sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' && echo 'Caches dropped'; echo; free -h; read -n1 -sp 'Press any key…'"])
      else if (b === Qt.MiddleButton) { if (root.hasVramClean) Quickshell.execDetached(["omarchy-launch-tui", "bash", root.vramCleanPath, "--pause"]) }
      else Quickshell.execDetached(["omarchy-launch-tui", "btop"])
    }
  }

  // Hover card: a short delay so sweeping the mouse across the bar doesn't
  // flash it, and it closes as soon as the pointer leaves the widget.
  // The bar calls close() when another popout takes over.
  function close() { hoverOpen = false }

  Timer {
    id: hoverDelay
    interval: 250
    onTriggered: root.hoverOpen = button.tooltipHovered
  }
  Connections {
    target: button
    function onTooltipHoveredChanged() {
      if (button.tooltipHovered) hoverDelay.restart()
      else { hoverDelay.stop(); root.hoverOpen = false }
    }
  }

  PopupCard {
    id: card
    anchorItem: button
    bar: root.bar
    owner: root
    triggerMode: "hover"
    open: root.hoverOpen
    contentWidth: card.fittedContentWidth(Style.space(300))
    contentHeight: card.fittedContentHeight(cardColumn.implicitHeight)

    Column {
      id: cardColumn
      anchors.fill: parent
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        text: "System"
        color: Commons.Color.popups.text
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Repeater {
        model: root.metrics

        Column {
          required property var modelData
          width: cardColumn.width
          spacing: Style.space(5)

          Item {
            width: parent.width
            height: rowLabel.implicitHeight

            Text {
              id: rowLabel
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: modelData.label
              color: Commons.Color.popups.text
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              anchors.left: rowLabel.right
              anchors.leftMargin: Style.space(8)
              anchors.baseline: rowLabel.baseline
              textFormat: Text.PlainText
              text: modelData.sub || ""
              color: Commons.Color.popups.text
              opacity: 0.6
              font.family: button.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right
              anchors.baseline: rowLabel.baseline
              textFormat: Text.PlainText
              text: Math.round(modelData.value) + "%"
              color: root.levelColor(modelData.value)
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          Rectangle {
            width: parent.width
            height: 6
            radius: 3
            color: Qt.alpha(Commons.Color.popups.text, 0.12)

            Rectangle {
              height: parent.height
              radius: parent.radius
              width: Math.max(modelData.value > 0 ? parent.height : 0, parent.width * Math.max(0, Math.min(100, modelData.value)) / 100)
              color: root.levelColor(modelData.value)
              Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
            }
          }
        }
      }

      Text {
        visible: root.swapLabel !== ""
        textFormat: Text.PlainText
        text: "Swap  " + root.swapLabel + (root.gpuName !== "" ? "      " + root.gpuName : "")
        color: Commons.Color.popups.text
        opacity: 0.6
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle { width: parent.width; height: 1; color: Qt.alpha(Commons.Color.popups.text, 0.12) }

      Column {
        spacing: Style.space(3)
        Repeater {
          model: root.hasVramClean
            ? [["Left click", "btop"], ["Right click", "free RAM caches"], ["Middle click", "free VRAM"]]
            : [["Left click", "btop"], ["Right click", "free RAM caches"]]
          Row {
            required property var modelData
            spacing: Style.space(8)
            Text {
              width: Style.space(80)
              textFormat: Text.PlainText
              text: modelData[0]
              color: Commons.Color.popups.text
              opacity: 0.6
              font.family: button.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              textFormat: Text.PlainText
              text: modelData[1]
              color: Commons.Color.popups.text
              font.family: button.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
