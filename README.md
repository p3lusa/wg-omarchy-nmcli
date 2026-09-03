# WireGuard VPN (wg-omarchy-nmcli)

A WireGuard VPN widget for the [Omarchy](https://omarchy.org) Quattro bar,
driven by [NetworkManager](https://networkmanager.dev) via `nmcli`. It shows
the tunnel state in the bar and — like Omarchy's built-in Wi-Fi menu —
**left-click opens a themed popup** with the live connection details, one-click
connect / disconnect, and one-click import of your `.conf` into
NetworkManager.

## Features

- Bar icon with live WireGuard state (polls every few seconds)
- **Left-click**: opens a themed dropdown panel (no right-click anywhere)
- Panel shows **IP / gateway / peer / last handshake** while the tunnel is up,
  plus live **ping, packet loss, and download / upload speed** (polled every
  1.5 s while the panel is open)
- **DNS is read-only on purpose**: the panel shows the DNS servers from your
  WireGuard config (the only leak-free source) but never edits them
- **Connect / Disconnect** button and **Import config** action (replaces the
  old right-click import)
- **Import config** is always visible: it uses your `configFile` setting if
  set, otherwise falls back to `~/.config/wireguard/<name>.conf` and
  `/etc/wireguard/<name>.conf`. If none of those exist the button is disabled
  and says so.
- Full keyboard navigation (↑/↓/←/→, Enter, Esc, `r` to refresh)
- Theme-aware: every color is derived from the bar theme, so a theme switch
  repaints the panel live

## Install

```sh
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable
# non-interactive (no prompts):
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable --yes
```

> **Note:** `omarchy plugin add` only clones the plugin into
> `~/.config/omarchy/plugins/` and registers the widget. It does **not**
> create or import anything into NetworkManager — the first-time import of your
> `wg0.conf` is the in-panel **Import config** button (or `nmcli connection
> import type wireguard file …` from a terminal).

### Dependencies

- `networkmanager` (and a running NetworkManager — Omarchy ships it)
- `wireguard-tools` (`wg show` — peer key + last handshake)
- A WireGuard config file the widget can read (see Configure)
- Optional: a `sudo` rule for the current user to run `wg show` without a
  password (e.g. `Cmnd_Alias WG = /usr/bin/wg` +
  `%omarchy ALL=(root) NOPASSWD: WG` or whatever the local convention is).
  Without it the **Last handshake** cell stays empty; everything else still
  works.

## Usage

The widget polls NetworkManager for a wireguard connection named `wg0`
(default). The icon is bright when connected, dimmed when the connection is
unknown.

| Action | Effect |
|---|---|
| Left-click (icon) | Open / close the panel |
| **Connect / Disconnect** | `nmcli connection up wg0` / `nmcli connection down wg0` |
| **Import config** | `nmcli connection import type wireguard file <path>` (auto-fallback: delete + re-import if the connection already exists) |

### Importing your wg0.conf

1. (Optional) Set `configFile` — e.g. `~/.config/wireguard/wg0.conf`.
   Without it the widget probes `~/.config/wireguard/<name>.conf` then
   `/etc/wireguard/<name>.conf`.
2. Open the panel and click **Import config**. NetworkManager imports the
   connection and names it after the `[Interface]` section (usually `wg0`),
   matching the default `connectionName`.
3. Click **Connect tunnel**.

> If the import fails with "connection already exists", the widget retries by
> deleting the stale connection and re-importing. Manual equivalent:
> `nmcli connection delete wg0 && nmcli connection import type wireguard
> file ~/.config/wireguard/wg0.conf`.

### Where the live numbers come from

| Cell | Source |
|---|---|
| IP | `ip -4 addr show dev <name>` |
| Gateway | `ip route show dev <name>` (first `default`); falls back to the config `Endpoint` when the tunnel has no default route (host-route setups) |
| Peer key | `wg show <name>` → `peer:` line (needs `wireguard-tools`) |
| Last handshake | `wg show <name>` → `latest handshake` (falls back to `sudo -n wg show` — silent no-op if sudoers is not configured) |
| DNS | `nmcli -t dev show <name>` — **display only** |
| Ping / Loss | `ping -c 2 -W 2 <Endpoint>` against the config endpoint |
| Download / Upload | Δ of `/sys/class/net/<name>/statistics/{rx,tx}_bytes` between consecutive 1.5 s polls (sample kept in `/tmp/wg-omarchy-nmcli-rate.<name>`) |

## Configure

Settings live in two places: **Setup › Plugins** (rendered from the manifest
`barWidget.schema`), or inline on the widget entry in
`~/.config/omarchy/shell.json`:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        {
          "id": "io.github.p3lu.wg-omarchy-nmcli",
          "connectionName": "wg0",
          "pollIntervalSec": 4,
          "configFile": "~/.config/wireguard/wg0.conf"
        }
      ]
    }
  }
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `connectionName` | string | `wg0` | NetworkManager connection name to toggle |
| `pollIntervalSec` | integer | `4` | State polling interval (1–600 s) |
| `configFile` | string | *(empty)* | Path passed to `nmcli connection import`. Empty → auto-discovery of `~/.config/wireguard/<name>.conf` then `/etc/wireguard/<name>.conf`. |

Move the widget to another bar section:

```sh
omarchy bar move io.github.p3lu.wg-omarchy-nmcli --section left
```

## IPC

This is a **bar-widget** (not a panel plugin), so the Quickshell CLI (`qs`)
is the way to reach it — `omarchy-shell shell call` only routes to panel
plugins and always returns `unknown` for bar-widgets:

```sh
qs ipc show | grep -A 12 wg-omarchy-nmcli   # list registered methods
qs ipc call io.github.p3lu.wg-omarchy-nmcli status
qs ipc call io.github.p3lu.wg-omarchy-nmcli setStatus up
qs ipc call io.github.p3lu.wg-omarchy-nmcli setStatus down
qs ipc call io.github.p3lu.wg-omarchy-nmcli importConfig
qs ipc call io.github.p3lu.wg-omarchy-nmcli toggle
```

## Architecture

A single `Widget.qml` (the `bar-widget` entry point) extends `qs.Ui.Panel` —
the base class that owns the bar button + popup lifecycle (`open` / `close` /
`toggle`, `controller`, `setting()`). The base class's auto-generated
`IpcHandler` is disabled (`manageIpc: false`) and replaced with one that
exposes the domain methods; every IPC function carries **explicit** parameter
and return types because Quickshell only registers typed functions. The
always-on probe drives the bar icon even while the panel is closed; a faster
1.5 s poll runs while the panel is open and the tunnel is up to feed the
metrics card.

## Update lifecycle (important)

Omarchy compiles each bar-widget entry point **once** and caches the
`Component` keyed by its file URL. An in-place `omarchy plugin update <id>`
that keeps the same entry-point filename (`Widget.qml`) will **not**
recompile the QML on rescan — the old compiled component keeps serving.

**After updating this plugin, always run `omarchy restart shell`.**

Verify the new code is live:

```sh
# journal must be warning-free (no "cannot be used across IPC", no
# "Plugin widget ... failed"):
journalctl --user -u omarchy-shell -n 50 --no-pager | grep -iE 'warn|error'

# the IPC methods of THIS version must be listed:
qs ipc show | grep -A 12 wg-omarchy-nmcli
```

## Remove

```sh
omarchy plugin remove io.github.p3lu.wg-omarchy-nmcli
# optional: remove the imported NM connection
nmcli connection delete wg0
```

## Troubleshooting

- **Icon dimmed, panel says "No connection found"** — NetworkManager has no
  connection named `connectionName`. Set `configFile` and use **Import
  config**, or fix `connectionName`.
- **Toggle fails** — the connection exists but `up` failed; run
  `nmcli connection up wg0` in a terminal for the error.
- **Gateway / ping / loss empty while connected** — the widget reads the
  `Endpoint` from your config (auto-discovery paths). If your config lives
  elsewhere, set `configFile`. Gateway also appears when the tunnel has no
  default route (host-route) — it then shows the endpoint.
- **Last handshake empty** — `wg show` needs root. Either add a
  passwordless sudo rule for `wg` (see Dependencies) or accept an empty cell;
  the rest of the panel is unaffected.
- **Download / Upload shows "--" on the first open** — the rate is computed
  between two consecutive polls; it populates ~1.5 s after the panel opens
  (or after the tunnel starts).
- **Config path with `~`** — the widget expands a leading `~/` to your home
  directory before invoking the import.
- **Debug logs** — `qs log -p "$OMARCHY_PATH/shell" --tail 100`.

## License

MIT — see [LICENSE](LICENSE).
