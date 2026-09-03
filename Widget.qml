import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Single-file bar widget, mirroring the first-party network (Wi-Fi) plugin:
// this Panel is BOTH the bar icon (BarIconButton) and the left-click popup
// (KeyboardPanel). The base Panel class owns bar/settings/ipcTarget/controller/
// opened/open()/close()/toggle()/setting(); we add the WireGuard state, the
// live detail probe (ip/gateway/peer/handshake/ping/loss/throughput), the
// themed status card (design style B), and the connect/disconnect + import
// actions. DNS is intentionally NOT managed here: the WireGuard config's own
// DNS is the only leak-free source, so the panel only shows it (read-only).
Panel {
  id: root
  moduleName: "io.github.p3lu.wg-omarchy-nmcli"
  ipcTarget: "io.github.p3lu.wg-omarchy-nmcli"
  // The base Panel auto-creates a generic IpcHandler; we disable it so we can
  // expose the domain methods (status / setStatus / importConfig) ourselves.
  manageIpc: false

  // ---- settings -----------------------------------------------------------
  readonly property string connName: setting("connectionName", "wg0")
  readonly property string cfgPath: String(setting("configFile", "") || "").trim()

  // Config discovery for the import action: explicit setting first, then the
  // conventional per-connection locations. The button is always visible; if
  // nothing resolves it reports so and the import is disabled.
  readonly property var cfgCandidates: [
    cfgPath,
    "~/.config/wireguard/" + connName + ".conf",
    "/etc/wireguard/" + connName + ".conf"
  ]

  function resolveConfigPath() {
    for (var i = 0; i < root.cfgCandidates.length; i++) {
      var p = String(root.cfgCandidates[i] || "").trim()
      if (p === "") continue
      if (p.indexOf("~/") === 0) p = Qt.application.homePath() + p.slice(1)
      if (root.fileExists(p)) return p
    }
    return ""
  }

  function fileExists(path) {
    if (!Qt.fileExists) return false
    return Qt.fileExists(path)
  }

  // ---- theme --------------------------------------------------------------
  // Every color derives from the bar / theme (same sources the first-party
  // network panel binds), so a theme switch repaints this panel live. The hex
  // fallbacks only apply if `bar` is somehow null.
  readonly property color foreground: bar ? bar.foreground : "#a9b1d6"
  readonly property color urgent: bar ? bar.urgent : "#f7768e"
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent, bar.urgent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent, bar.urgent) : "transparent"

  // ---- state --------------------------------------------------------------
  property bool on: false
  property bool connKnown: true
  property bool busy: false
  // { iface, ip, prefix, gateway, peer, endpoint, handshake, dns,
  //    ping, loss, tx, rx } — ping/loss/tx/rx only while the tunnel is up.
  property var details: ({ iface: "", ip: "", prefix: "", gateway: "", peer: "",
                           endpoint: "", handshake: "", dns: "",
                           ping: "", loss: "", tx: "", rx: "" })
  property string actionLabel: ""   // transient "Applying…" style feedback

  // ---- keyboard cursor ----------------------------------------------------
  // One cursor across the action rows (connect/disconnect, import).
  property int actionsIndex: 0
  property bool cursorActive: false
  readonly property int actionsCount: 2
  readonly property string statusText: !connKnown
    ? "No connection found"
    : (on ? "TUNNEL ACTIVE" : "NOT CONNECTED")
  readonly property color statusColor: connKnown ? (on ? foreground : dim) : urgent

  // ---- lifecycle ----------------------------------------------------------
  // Mirrors the first-party network panel: the base Panel's open()/toggle()
  // drive the popup; onOpenedChanged does the work.
  function close() {
    controller.hide()
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      actionsIndex = 0
      refresh()
    }
  }

  // ---- data ----------------------------------------------------------------
  function refresh() {
    probeStatus()
    refreshDetails()
  }

  function probeStatus() {
    if (statusProc.running) return
    statusProc.command = [
      "bash", "-lc",
      "nmcli -t -f NAME,TYPE connection show --active | grep -qxF '" + root.connName + ":wireguard' && exit 0; " +
      "nmcli -t -f NAME connection show | grep -qxF '" + root.connName + "' && exit 10; " +
      "exit 20"
    ]
    statusProc.running = true
  }

  function refreshDetails() {
    if (detailsProc.running) return
    detailsProc.command = ["bash", "-lc", root.detailsScript(), "x", root.connName]
    detailsProc.running = true
  }

  function detailsScript() {
    // Connection name arrives as $1 (argv, not embedded) so names with spaces
    // or shell metacharacters survive. awk is used only for simple field
    // extraction (the dev VM's gawk rejects multi-char class syntax); the
    // fiddly text surgery is sed/tr/xargs.
    //
    // Live metrics:
    //  - ping/loss: one 2-packet ping at the peer endpoint (2s cap)
    //  - tx/rx: delta of /sys/class/net/$1/statistics over the previous poll
    //    (previous sample kept in /tmp), so the 1.5s panel poll yields rates
    //  - handshake: `wg show` needs root; try `sudo -n` and degrade silently
    //    to empty when sudoers is not configured for the user.
    //  - gateway: default route on the iface; when absent (host-route setups)
    //    fall back to the WG endpoint, which is where the traffic actually goes.
    return "c=\"$1\";" +
      "ip=$(ip -4 -o addr show dev \"$c\" 2>/dev/null | awk '{print $4}' | head -n1);" +
      "gw=$(ip route show dev \"$c\" 2>/dev/null | awk '/default/ {print $3; exit}');" +
      "peer=$(wg show \"$c\" 2>/dev/null | awk '/^peer:/ {print $2; exit}');" +
      "hs=$(wg show \"$c\" 2>/dev/null | awk '/handshake/ {print $3, $4, $5; exit}');" +
      "if [ -z \"$hs\" ]; then hs=$(sudo -n wg show \"$c\" 2>/dev/null | awk '/handshake/ {print $3, $4, $5; exit}'); fi;" +
      "dns=$(nmcli -t -f IPV4.DNS,IPV6.DNS dev show \"$c\" 2>/dev/null | sed -e 's/^IPV4\\.DNS://' -e 's/^IPV6\\.DNS://' | tr ':,' ' ' | xargs);" +
      "ep=$(grep -s '^Endpoint=' ~/.config/wireguard/\"$c\".conf /etc/wireguard/\"$c\".conf 2>/dev/null | head -n1 | cut -d= -f2-);" +
      "case \"$ep\" in" +
      "  \\[*\\]*) ep=${ep#\\[}; ep=${ep%%\\]*} ;;" +
      "  *:*) ep=${ep%%:*} ;;" +
      "esac;" +
      "ping=\"\"; loss=\"\";" +
      "if [ -n \"$ep\" ]; then" +
      "  pout=$(ping -c 2 -W 2 -q \"$ep\" 2>/dev/null);" +
      "  loss=$(printf '%s\\n' \"$pout\" | sed -n 's/.* \\([0-9.]*\\)% packet loss.*/\\1/p');" +
      "  ping=$(printf '%s\\n' \"$pout\" | sed -n 's/.* = \\([^ ]*\\) ms.*/\\1/p' | awk -F'/' '{print $2}');" +
      "fi;" +
      "tx=\"\"; rx=\"\";" +
      "if [ -f /sys/class/net/\"$c\"/statistics/tx_bytes ]; then" +
      "  t=$(cat /sys/class/net/\"$c\"/statistics/tx_bytes 2>/dev/null);" +
      "  r=$(cat /sys/class/net/\"$c\"/statistics/rx_bytes 2>/dev/null);" +
      "  n=$(date +%s);" +
      "  f=\"/tmp/wg-omarchy-nmcli-rate.\"$c;" +
      "  if [ -f \"$f\" ]; then" +
      "    read pt pr pn < \"$f\" 2>/dev/null;" +
      "    if [ -n \"$pn\" ] && [ \"$n\" -gt \"$pn\" ]; then" +
      "      tx=$(( (t - pt) / (n - pn) ));" +
      "      rx=$(( (r - pr) / (n - pn) ));" +
      "      if [ \"$tx\" -lt 0 ]; then tx=0; fi;" +
      "      if [ \"$rx\" -lt 0 ]; then rx=0; fi;" +
      "    fi;" +
      "  fi;" +
      "  printf '%s %s %s' \"$t\" \"$r\" \"$n\" > \"$f\" 2>/dev/null;" +
      "fi;" +
      "printf 'iface\\t%s\\n' \"$c\";" +
      "printf 'ip\\t%s\\n' \"${ip:-}\";" +
      "printf 'gateway\\t%s\\n' \"${gw:-${ep:-}}\";" +
      "printf 'peer\\t%s\\n' \"${peer:-}\";" +
      "printf 'endpoint\\t%s\\n' \"${ep:-}\";" +
      "printf 'handshake\\t%s\\n' \"${hs:-}\";" +
      "printf 'dns\\t%s\\n' \"${dns:-}\";" +
      "printf 'ping\\t%s\\n' \"${ping:-}\";" +
      "printf 'loss\\t%s\\n' \"${loss:-}\";" +
      "printf 'tx\\t%s\\n' \"${tx:-}\";" +
      "printf 'rx\\t%s\\n' \"${rx:-}\""
  }

  function humanRate(bytesPerSec) {
    var v = Number(bytesPerSec || 0)
    if (v <= 0) return ""
    if (v >= 1024 * 1024) return (Math.round(v / 102.4) / 10) + " MiB/s"
    return Math.round(v / 1024) + " KiB/s"
  }

  function updateDetails(text) {
    var parts = ({ iface: root.details.iface, ip: root.details.ip, prefix: root.details.prefix,
                   gateway: root.details.gateway, peer: root.details.peer,
                   endpoint: root.details.endpoint, handshake: root.details.handshake,
                   dns: root.details.dns, ping: root.details.ping, loss: root.details.loss,
                   tx: root.details.tx, rx: root.details.rx })
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab < 0) continue
      var key = lines[i].slice(0, tab)
      var value = lines[i].slice(tab + 1).trim()
      if (key === "ip" && value !== "") {
        var slash = value.lastIndexOf("/")
        if (slash > 0) { parts.ip = value.slice(0, slash); parts.prefix = value.slice(slash + 1) }
        else parts.ip = value
      } else if (key in parts) {
        parts[key] = value
      }
    }
    root.details = parts
  }

  // ---- actions ----------------------------------------------------------------
  function toggleTunnel() {
    if (root.busy || !root.connKnown) return
    root.busy = true
    root.actionLabel = root.on ? "Disconnecting…" : "Connecting…"
    actionProc.command = ["nmcli", "connection", root.on ? "down" : "up", root.connName]
    actionProc.running = true
  }

  function importConfig() {
    var path = root.resolveConfigPath()
    if (path === "" || root.busy) return
    root.busy = true
    root.actionLabel = "Importing…"
    actionProc.command = ["bash", "-lc",
      "{ nmcli connection import type wireguard file " + Util.shellQuote(path) +
      " 2>/dev/null || { nmcli connection delete " + root.connName +
      " 2>/dev/null; nmcli connection import type wireguard file " + Util.shellQuote(path) + "; }; }"]
    actionProc.running = true
  }

  // ---- keyboard nav ---------------------------------------------------------------
  function moveFocus(dy) {
    // Two rows: clamp the index; direction only matters for the first press.
    if (dy > 0 && root.actionsIndex === 0) root.actionsIndex = 1
    else if (dy < 0 && root.actionsIndex === 1) root.actionsIndex = 0
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (root.actionsIndex === 0) root.toggleTunnel()
    else if (root.actionsIndex === 1) root.importConfig()
  }

  // ---- IPC ------------------------------------------------------------------------
  IpcHandler {
    target: "io.github.p3lu.wg-omarchy-nmcli"

    // Every IPC handler function needs EXPLICIT argument and return types,
    // or Quickshell does not register it (WARN scene: "Type of argument 1
    // (...) cannot be used across IPC"). Allowed: string, int, bool, real,
    // color, void — matches the 0.2.0 handler and the first-party panels.
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return JSON.stringify({ on: root.on, connection: root.connName, known: root.connKnown,
                              ip: root.details.ip, ping: root.details.ping,
                              loss: root.details.loss, tx: root.details.tx, rx: root.details.rx })
    }
    function setStatus(target: string): void {
      var up = target === "up" || target === "on" || target === "true"
      if (up === root.on) return
      root.busy = true
      root.actionLabel = up ? "Connecting…" : "Disconnecting…"
      actionProc.command = ["nmcli", "connection", up ? "up" : "down", root.connName]
      actionProc.running = true
    }
    function importConfig(): void { root.importConfig() }
    function refreshStatus(): void { root.refresh() }
  }

  // ---- processes --------------------------------------------------------------------
  Process {
    id: statusProc
    onExited: function(code) {
      root.on = (code === 0)
      root.connKnown = (code !== 20)
    }
  }

  Process {
    id: detailsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateDetails(text)
    }
  }

  Process {
    id: actionProc
    onExited: function(code) {
      root.busy = false
      root.actionLabel = ""
      Qt.callLater(root.refresh)
    }
  }

  // Always-on probe drives the bar icon even while the panel is closed.
  Timer {
    id: statusPoll
    interval: root.setting("pollIntervalSec", 4) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.probeStatus()
  }

  // Faster detail polling while the panel is open so the card catches up as
  // soon as NetworkManager finishes activating the connection. The rate
  // script keeps its previous sample in /tmp, so consecutive polls yield the
  // tx/rx throughput.
  Timer {
    id: detailsPoll
    interval: 1500
    repeat: true
    running: root.opened && root.on
    onTriggered: root.refreshDetails()
  }

  Component.onCompleted: root.refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- bar icon ---------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Connected = md-key U+F0306. Disconnected candidate pending user choice
    // (current md-bookmark U+F00C0 reads as a label, not a state).
    text: root.on ? "\u{F0306}" : "\u{F00C0}"
    active: root.on
    dimmed: !root.connKnown
    tooltipText: !root.connKnown
      ? "WireGuard: no connection found — open the panel to import"
      : (root.on
          ? "WireGuard: connected — open the panel"
          : "WireGuard: disconnected — open the panel")
    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  // ---- popup ---------------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          root.actionsIndex = 0
          if (dy !== 0) return
        }
        if (dy !== 0) root.moveFocus(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.spacing.md

      // ---- Status card (design style B) ----
      Item {
        id: card
        width: parent.width
        implicitHeight: cardInner.implicitHeight + Style.spacing.md * 2

        BorderSurface {
          anchors.fill: parent
          color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.on ? Color.accent : root.dim)
          radius: Style.cornerRadius
        }

        Row {
          id: cardInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.md
          anchors.leftMargin: Style.spacing.md
          anchors.rightMargin: Style.spacing.md
          spacing: Style.spacing.md

          // Rail: status dot + glyph
          Rectangle {
            id: rail
            width: Style.space(46)
            height: cardInner.height
            radius: Math.max(1, Style.space(6))
            color: root.on ? Color.accent : root.dim
            opacity: 0.16

            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(10)
                height: width
                radius: width / 2
                anchors.horizontalCenter: parent.horizontalCenter
                color: root.on ? Color.accent : (root.connKnown ? root.dim : root.urgent)
              }

              Text {
                text: root.on ? "\u{F0306}" : "\u{F00C0}"
                color: root.connKnown
                  ? (root.on ? root.foreground : root.dim)
                  : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                anchors.horizontalCenter: parent.horizontalCenter
              }
            }
          }

          Column {
            id: mainCol
            width: parent.width - rail.width - Style.spacing.md
            spacing: Style.space(2)

            Text {
              text: "WireGuard VPN · " + root.connName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusText
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              visible: root.statusText !== ""
              height: visible ? implicitHeight : 0
            }

            // Detail grid — mounted always so late samples never reflow the
            // card; cells read "--" until the first probe lands. Metrics rows
            // only make sense with the tunnel up.
            GridLayout {
              id: dataGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(16)
              rowSpacing: Style.space(8)
              visible: root.on

              DCell { label: "IP"; value: root.details.ip !== ""
                ? root.details.ip + (root.details.prefix !== "" ? "/" + root.details.prefix : "") : "" }
              DCell { label: "Gateway"; value: root.details.gateway }
              DCell { label: "Peer key"; value: root.details.peer }
              DCell { label: "Last handshake"; value: root.details.handshake }
              DCell { label: "Ping"; value: root.details.ping !== "" ? root.details.ping + " ms" : "" }
              DCell { label: "Loss"; value: root.details.loss !== "" ? root.details.loss + " %" : "" }
              DCell { label: "Download"; value: root.humanRate(root.details.rx) }
              DCell { label: "Upload"; value: root.humanRate(root.details.tx) }
            }

            // The WireGuard config's own DNS, read-only: it is the only
            // leak-free source, so this panel shows it but never changes it.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.on && root.details.dns !== ""
              height: visible ? implicitHeight : 0
              text: "DNS: " + root.details.dns
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }

      // ---- Actions ----
      PanelSeparator {
        foreground: root.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Button {
          id: toggleBtn
          width: parent.width
          text: root.busy && root.actionLabel !== ""
            ? root.actionLabel
            : (root.on ? "Disconnect tunnel" : "Connect tunnel")
          fontSize: Style.font.body
          foreground: root.busy ? root.dim : (root.on ? root.urgent : root.foreground)
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          active: root.cursorActive && root.actionsIndex === 0
          opacity: (root.busy || !root.connKnown) ? 0.5 : 1
          onClicked: {
            if (root.busy || !root.connKnown) return
            root.toggleTunnel()
          }
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.actionsIndex = 0
          }
        }

        Button {
          id: importBtn
          width: parent.width
          text: root.busy && root.actionLabel === "Importing…"
            ? root.actionLabel
            : (root.resolveConfigPath() !== ""
                ? "Import config (" + root.resolveConfigPath() + ")"
                : "Import config to NetworkManager — no .conf found")
          fontSize: Style.font.bodySmall
          foreground: root.busy ? root.dim : root.dim
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: root.cursorActive && root.actionsIndex === 1
          opacity: (root.busy || root.resolveConfigPath() === "") ? 0.5 : 1
          onClicked: { if (root.busy || root.resolveConfigPath() === "") return; root.importConfig() }
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.actionsIndex = 1
          }
        }
      }
    }
  }

  // ---- reusable components (top-level, per the first-party network panel) ----
  component DCell: Item {
    required property string label
    required property string value
    implicitWidth: Math.max(Style.space(90), (dataGrid.width - Style.space(16)) / 2)
    implicitHeight: kc.implicitHeight + kv.implicitHeight + Style.space(2)

    Text {
      id: kc
      textFormat: Text.PlainText
      text: label.toUpperCase()
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      id: kv
      textFormat: Text.PlainText
      text: value !== "" ? value : "--"
      color: value !== "" ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: parent.width
    }
  }
}
