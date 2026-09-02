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
// detail probe, DNS control, and the themed status card (design style B).
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
  // { iface, ip, prefix, gateway, peer, handshake, dns }
  property var details: ({ iface: "", ip: "", prefix: "", gateway: "", peer: "", handshake: "", dns: "" })
  property string dnsProvider: ""
  property string pendingDns: ""
  property string customDns: ""
  property bool customOpen: false
  property string actionLabel: ""   // transient "Applying…" style feedback

  readonly property var dnsProviders: ["DHCP", "Cloudflare", "Google"]
  readonly property var knownDns: ({
    DHCP: "from DHCP",
    Cloudflare: "1.1.1.1, 1.0.0.1",
    Google: "8.8.8.8, 8.8.4.4"
  })

  // ---- keyboard cursor ----------------------------------------------------
  // One cursor across the whole panel, like the network panel: sections
  // "dns" (pills) → "custom" (inline editor) → "actions" (toggle, import).
  property string focusSection: "dns"
  property int dnsIndex: 0
  property int actionsIndex: 0
  property bool cursorActive: false
  readonly property int actionsCount: cfgPath !== "" ? 2 : 1
  readonly property string statusText: !connKnown
    ? "No connection found"
    : (on ? "TUNNEL ACTIVE" : "NOT CONNECTED")
  readonly property color statusColor: connKnown ? (on ? foreground : dim) : urgent

  // ---- lifecycle ----------------------------------------------------------
  // Mirrors the first-party network panel: the base Panel's open()/toggle()
  // drive the popup; onOpenedChanged does the work. close() also drops the
  // inline DNS editor so a reopened panel always starts clean.
  function close() {
    closeCustom()
    controller.hide()
  }

  onOpenedChanged: {
    if (opened) {
      customOpen = false
      customDns = ""
      cursorActive = false
      focusSection = "dns"
      dnsIndex = 0
      actionsIndex = 0
      refresh()
    }
  }

  // ---- data ----------------------------------------------------------------
  function refresh() {
    probeStatus()
    refreshDetails()
    refreshDns()
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

  function refreshDns() {
    if (dnsProc.running) return
    dnsProc.command = ["bash", "-lc",
      "command -v omarchy-dns >/dev/null 2>&1 && omarchy-dns 2>/dev/null | head -1 || echo DHCP"]
    dnsProc.running = true
  }

  function detailsScript() {
    // The connection name arrives as $1 (argv, not embedded) so names with
    // spaces or shell metacharacters survive. awk is used only for simple
    // field extraction (the dev VM's gawk rejects multi-char class syntax).
    return "c=\"$1\";" +
      "ip=$(ip -4 -o addr show dev \"$c\" 2>/dev/null | awk '{print $4}' | head -n1);" +
      "gw=$(ip route show dev \"$c\" 2>/dev/null | awk '/default/ {print $3; exit}');" +
      "peer=$(wg show \"$c\" 2>/dev/null | awk '/public key/ {print $3; exit}');" +
      "hs=$(wg show \"$c\" 2>/dev/null | awk '/last handshake/ {print $3, $4, $5; exit}');" +
      "dns=$(nmcli -t -f IPV4.DNS,IPV6.DNS dev show \"$c\" 2>/dev/null | sed -e 's/^IPV4\\.DNS://' -e 's/^IPV6\\.DNS://' | tr ':,' ' ' | xargs);" +
      "printf 'iface\\t%s\\n' \"$c\";" +
      "printf 'ip\\t%s\\n' \"${ip:-}\";" +
      "printf 'gateway\\t%s\\n' \"${gw:-}\";" +
      "printf 'peer\\t%s\\n' \"${peer:-}\";" +
      "printf 'handshake\\t%s\\n' \"${hs:-}\";" +
      "printf 'dns\\t%s\\n' \"${dns:-}\""
  }

  function updateDetails(text) {
    var parts = ({ iface: root.details.iface, ip: root.details.ip, prefix: root.details.prefix,
                   gateway: root.details.gateway, peer: root.details.peer,
                   handshake: root.details.handshake, dns: root.details.dns })
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
    if (root.cfgPath === "" || root.busy) return
    var path = root.cfgPath
    if (path.indexOf("~/") === 0) path = Qt.application.homePath() + path.slice(1)
    root.busy = true
    root.actionLabel = "Importing…"
    actionProc.command = ["bash", "-lc",
      "nmcli connection import type wireguard file " + Util.shellQuote(path)]
    actionProc.running = true
  }

  function setDns(provider) {
    if (!provider || root.busy) return
    if (provider === "Custom") {
      openCustom()
      return
    }
    root.pendingDns = provider
    root.busy = true
    root.actionLabel = "Setting " + provider + "…"
    actionProc.command = ["bash", "-lc",
      "command -v omarchy-dns >/dev/null 2>&1 && omarchy-dns " + provider +
      " || { nmcli connection modify " + root.connName +
      " ipv4.dns '" + root.dnsServersFor(provider) + "'" +
      " && nmcli -t -f NAME connection show --active | grep -qxF '" + root.connName + ":wireguard'" +
      " && nmcli connection up " + root.connName + "; }"]
    actionProc.running = true
  }

  function dnsServersFor(provider) {
    if (provider === "Cloudflare") return "1.1.1.1,1.0.0.1"
    if (provider === "Google") return "8.8.8.8,8.8.4.4"
    return ""   // DHCP: empty clears the override
  }

  function openCustom() {
    customOpen = true
    focusSection = "custom"
    cursorActive = true
    if (root.details.dns !== "") customDns = root.details.dns
    Qt.callLater(function() { customField.forceActiveFocus() })
  }

  function closeCustom() {
    customOpen = false
    customDns = ""
    if (focusSection === "custom") focusSection = "dns"
  }

  function applyCustomDns() {
    var raw = String(root.customDns || "").replace(/,/g, " ").trim()
    if (raw === "" || root.busy) return
    var v4 = [], v6 = []
    var parts = raw.split(/\s+/)
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].indexOf(":") >= 0) v6.push(parts[i])
      else v4.push(parts[i])
    }
    root.pendingDns = "Custom"
    root.busy = true
    root.actionLabel = "Applying DNS…"
    actionProc.command = ["bash", "-lc",
      "nmcli connection modify " + root.connName +
      " ipv4.dns '" + v4.join(",") + "'" +
      (v6.length ? " ipv6.dns '" + v6.join(",") + "'" : " ipv6.dns ''") +
      " && { nmcli -t -f NAME connection show --active | grep -qxF '" + root.connName + ":wireguard' && nmcli connection up " + root.connName + "; }"]
    actionProc.running = true
  }

  // ---- keyboard nav ---------------------------------------------------------------
  function selectDnsByDelta(delta) {
    root.dnsIndex = Math.max(0, Math.min(root.dnsProviders.length - 1, root.dnsIndex + delta))
  }

  function moveFocus(dy) {
    if (dy > 0) {
      if (root.focusSection === "dns") root.focusSection = root.customOpen ? "custom" : "actions"
      else if (root.focusSection === "custom") root.focusSection = "actions"
    } else {
      if (root.focusSection === "actions") root.focusSection = root.customOpen ? "custom" : "dns"
      else if (root.focusSection === "custom") root.focusSection = "dns"
    }
    if (root.focusSection === "actions" && root.cfgPath === "") root.actionsIndex = 0
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (root.focusSection === "dns") root.setDns(root.dnsProviders[root.dnsIndex])
    else if (root.focusSection === "custom") root.applyCustomDns()
    else if (root.focusSection === "actions") {
      if (root.actionsIndex === 0) root.toggleTunnel()
      else if (root.cfgPath !== "" && root.actionsIndex === 1) root.importConfig()
    }
  }

  // ---- IPC ------------------------------------------------------------------------
  IpcHandler {
    target: "io.github.p3lu.wg-omarchy-nmcli"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function status() {
      return JSON.stringify({ on: root.on, connection: root.connName, known: root.connKnown, dns: root.dnsProvider })
    }
    function setStatus(target) {
      var up = target === "up" || target === "on" || target === "true"
      if (up === root.on) return
      root.busy = true
      root.actionLabel = up ? "Connecting…" : "Disconnecting…"
      actionProc.command = ["nmcli", "connection", up ? "up" : "down", root.connName]
      actionProc.running = true
    }
    function importConfig() { root.importConfig() }
    function setDns(provider) { root.setDns(provider) }
    function refreshStatus() { root.probeStatus() }
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
    id: dnsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dnsProvider = String(text || "").trim() || "DHCP"
    }
  }

  Process {
    id: actionProc
    onExited: function(code) {
      if (root.pendingDns !== "") {
        if (code === 0) root.dnsProvider = root.pendingDns
        root.pendingDns = ""
      }
      root.busy = false
      root.actionLabel = ""
      root.closeCustom()
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

  // Faster detail / DNS polling while the panel is open so the card catches
  // up as soon as NetworkManager finishes activating a connection.
  Timer {
    id: detailsPoll
    interval: 1500
    repeat: true
    running: root.opened
    onTriggered: { root.refreshDetails(); root.refreshDns() }
  }

  Component.onCompleted: root.refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- bar icon ---------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Connected = wifi glyph U+F0306 (unchanged per decision);
    // Disconnected = shield U+F00C0 (user's choice from the proposals).
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
      // Freeze the cursor model while the inline DNS editor is open; the
      // TextField owns input until Esc/Enter/Cancel.
      blocked: root.customOpen && root.focusSection === "custom"

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          root.focusSection = "dns"
          root.dnsIndex = 0
          if (dy !== 0) return
        }
        if (dy !== 0) root.moveFocus(dy)
        else if (dx !== 0 && root.focusSection === "dns") root.selectDnsByDelta(dx)
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

          // Rail: status dot + shield
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
                text: root.on ? "\u{F0306}" : "\u{F00C0}"   // wifi / shield (Nerd Font)
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
            // card; cells read "--" until the first probe lands.
            GridLayout {
              id: dataGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(16)
              rowSpacing: Style.space(8)
              visible: root.on

              DCell {
                label: "IP"
                value: root.details.ip !== ""
                  ? root.details.ip + (root.details.prefix !== "" ? "/" + root.details.prefix : "")
                  : ""
              }
              DCell {
                label: "Gateway"
                value: root.details.gateway
              }
              DCell {
                label: "Peer"
                value: root.details.peer
              }
              DCell {
                label: "Last handshake"
                value: root.details.handshake !== "" ? root.details.handshake + " ago" : ""
              }
            }
          }
        }
      }

      // ---- DNS ----
      PanelSeparator {
        foreground: root.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "DNS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: dnsRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 4) / 4

          DnsPill { provider: "DHCP"; slot: 0 }
          DnsPill { provider: "Cloudflare"; slot: 1 }
          DnsPill { provider: "Google"; slot: 2 }
          DnsPill {
            provider: "Custom"
            slot: 3
            active: root.dnsProvider === "Custom" || root.customOpen
            onClicked: { if (root.busy) return; root.openCustom() }
            onHovered: function(isHovered) {
              if (!isHovered) return
              root.cursorActive = true
              root.focusSection = "dns"
              root.dnsIndex = 3
            }
          }
        }

        // Live servers currently in effect.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.details.dns === ""
          height: visible ? implicitHeight : 0
          text: "DNS: " + (root.dnsProvider !== "" ? (root.knownDns[root.dnsProvider] || root.dnsProvider) : "—")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.details.dns !== ""
          height: visible ? implicitHeight : 0
          text: "now: " + root.details.dns
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Inline custom-DNS editor.
        Item {
          width: parent.width
          visible: root.customOpen
          height: visible ? implicitHeight : 0
          implicitHeight: customField.implicitHeight + Style.space(4) + customApplyRow.implicitHeight

          TextField {
            id: customField
            width: parent.width
            text: root.customDns
            placeholderText: "1.1.1.1, 1.0.0.1"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            enabled: !root.busy

            onAccepted: root.applyCustomDns()
            onTextChanged: if (root.customOpen && text !== root.customDns) root.customDns = text
            Keys.onEscapePressed: {
              root.closeCustom()
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          Row {
            id: customApplyRow
            width: parent.width
            anchors.top: customField.bottom
            anchors.topMargin: Style.space(4)
            spacing: Style.space(6)

            Text {
              text: root.busy && root.focusSection === "custom" ? "Applying…" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              text: "Apply"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              active: root.cursorActive && root.focusSection === "custom"
              opacity: root.busy ? 0.5 : 1
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.applyCustomDns()
            }

            Button {
              text: "Cancel"
              fontSize: Style.font.bodySmall
              foreground: root.dim
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              anchors.verticalCenter: parent.verticalCenter
              onClicked: {
                root.closeCustom()
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
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
          active: root.cursorActive && root.focusSection === "actions" && root.actionsIndex === 0
          opacity: (root.busy || !root.connKnown) ? 0.5 : 1
          onClicked: {
            if (root.busy || !root.connKnown) return
            root.toggleTunnel()
          }
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.focusSection = "actions"
            root.actionsIndex = 0
          }
        }

        Button {
          id: importBtn
          width: parent.width
          visible: root.cfgPath !== ""
          height: visible ? implicitHeight : 0
          text: "Import config (" + root.cfgPath + ")"
          fontSize: Style.font.bodySmall
          foreground: root.busy ? root.dim : root.dim
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: root.cursorActive && root.focusSection === "actions" && root.actionsIndex === 1
          opacity: root.busy ? 0.5 : 1
          onClicked: { if (root.busy) return; root.importConfig() }
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.focusSection = "actions"
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

  component DnsPill: Button {
    required property string provider
    required property int slot
    width: dnsRow.cellWidth
    text: provider
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    active: root.dnsProvider === provider
    hasCursor: root.cursorActive && root.focusSection === "dns" && root.dnsIndex === slot
    opacity: root.busy ? 0.5 : 1
    onClicked: { if (root.busy) return; root.setDns(provider) }
    onHovered: function(isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.focusSection = "dns"
      root.dnsIndex = slot
    }
  }
}
