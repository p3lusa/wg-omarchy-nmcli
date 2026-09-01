import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.p3lu.wg-omarchy-nmcli"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Settings: Setup > Plugins (barWidget.schema) or inline in shell.json.
  readonly property string connName: setting("connectionName", "wg0")
  readonly property string cfgPath: String(setting("configFile", "") || "").trim()
  property bool busy: false
  property bool connKnown: true
  property var state: ({ on: false, loaded: false })
  readonly property bool on: state.on

  readonly property string hint: !root.connKnown
    ? (root.cfgPath !== ""
        ? "WireGuard: no connection — right-click to import " + root.cfgPath
        : "WireGuard: no connection found (set connectionName or configFile)")
    : (root.on
        ? "WireGuard: connected — left-click to disconnect"
        : "WireGuard: disconnected — left-click to connect")

  Timer {
    id: poll
    interval: root.setting("pollIntervalSec", 4) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  function refresh() {
    if (statusProbe.running) return
    statusProbe.command = ["bash", "-lc",
      "nmcli -t -f NAME,TYPE connection show --active | grep -qxF '" + root.connName + ":wireguard'; " +
      "test $? -eq 0 && exit 0; " +
      "nmcli -t -f NAME connection show | grep -qxF '" + root.connName + "'"]
    statusProbe.running = true
  }

  Process {
    id: statusProbe
    onExited: function(code) {
      // exit 0  -> tunnel up
      // exit 10 -> connection defined but down
      // exit 20 -> connection unknown
      root.state = ({ on: code === 0, loaded: true })
      root.connKnown = (code !== 20)
    }
  }

  Process {
    id: actionProc
    onExited: function() {
      root.busy = false
      Qt.callLater(root.refresh)
    }
  }

  function toggle() {
    if (root.busy || actionProc.running) return
    if (!root.connKnown) return
    root.busy = true
    actionProc.command = ["nmcli", "connection", root.on ? "down" : "up", root.connName]
    actionProc.running = true
  }

  function importConfig() {
    if (root.cfgPath === "" || root.busy || actionProc.running) return
    root.busy = true
    actionProc.command = ["bash", "-lc",
      "nmcli connection import type wireguard file " + Util.shellQuote(root.cfgPath)]
    actionProc.running = true
  }

  IpcHandler {
    target: "io.github.p3lu.wg-omarchy-nmcli"

    function status(): string {
      return JSON.stringify({ on: root.on, connection: root.connName, known: root.connKnown })
    }

    function toggle(): void {
      root.broadcast("toggle")
    }

    function refreshStatus(): void {
      root.broadcast("refresh")
    }

    function importConfig(): void {
      root.broadcast("importConfig")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.on ? "\u{F0306}" : "\u{F0302}"   // 󰌆 connected / 󰅫 disconnected
    active: root.on
    dimmed: !root.connKnown
    tooltipText: root.hint
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
      else if (b === Qt.RightButton) root.importConfig()
    }
  }
}
