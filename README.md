# WireGuard VPN (wg-omarchy-nmcli)

A WireGuard VPN widget for the [Omarchy](https://omarchy.org) Quattro bar, driven
by [NetworkManager](https://networkmanager.dev) via `nmcli`. It shows the tunnel
state in the bar and — like Omarchy's built-in Wi-Fi menu — **left-click opens a
themed popup** with the live connection details, DNS control, and one-click
connect / disconnect.

## Features

- Bar icon with live WireGuard state (polls every few seconds)
- **Left-click**: opens a themed dropdown panel (no right-click anywhere)
- Panel shows **IP / gateway / peer / last handshake** while the tunnel is up
- **DNS** section: DHCP · Cloudflare · Google pills, or an inline **Custom**
  editor (type servers, press Apply)
- **Connect / Disconnect** button and **Import config** action (replaces the
  old right-click import)
- Full keyboard navigation (↑/↓/←/→, Enter, Esc, `r` to refresh)
- Theme-aware: every color is derived from the bar theme, so a theme switch
  repaints the panel live

## Install

```sh
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable
# non-interactive (no prompts):
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable --yes
```

### Dependencies

- `networkmanager` (and a running NetworkManager — Omarchy ships it)
- `wireguard-tools` (for `wg` handshake inspection)
- A WireGuard config file you can read, e.g. `~/.config/wireguard/wg0.conf`
- `omarchy-dns` (the first-party DNS helper) if present — used when available,
  with a direct `nmcli` fallback otherwise

## Usage

The widget polls NetworkManager for a wireguard connection named `wg0`
(default). The icon is bright when connected, dimmed when the connection is
unknown, and shows a shield glyph when it is down.

| Action | Effect |
|---|---|
| Left-click (icon) | Open / close the panel |
| **Connect / Disconnect** | `nmcli connection up wg0` / `nmcli connection down wg0` |
| DNS pill | Switch DNS provider (`omarchy-dns <provider>` or `nmcli`) |
| **Custom** DNS | Inline editor → `nmcli connection modify … ipv4.dns / ipv6.dns` |
| **Import config** | `nmcli connection import type wireguard file <configFile>` |

### Importing your wg0.conf

1. Set `configFile` (see Configure below) — e.g. `~/.config/wireguard/wg0.conf`.
2. Open the panel and click **Import config**. NetworkManager imports the
   connection and names it after the `[Interface]` section (usually `wg0`),
   matching the default `connectionName`.
3. Click **Connect tunnel**.

> If the import fails with "connection already exists", delete the stale one
> first: `nmcli connection delete wg0` — or set a different `connectionName`
> and rename the `[Interface]` section in your config.

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
| `configFile` | string | *(empty)* | Path passed to `nmcli connection import`. Empty hides the **Import config** button. |

Move the widget to another bar section:

```sh
omarchy bar move io.github.p3lu.wg-omarchy-nmcli --section left
```

## IPC

```sh
omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli status
omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli setStatus up
omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli setDns Cloudflare
omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli importConfig
omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli toggle
```

## Architecture

A single `Panel.qml` (the `bar-widget` entry point) hosts both the bar icon
(`BarIconButton`) and the popup (`KeyboardPanel`), matching the first-party
Wi-Fi plugin. Connection state, details, and DNS are pulled through `Process`
calls (`nmcli`, `ip`, `wg`) that poll on a timer while the panel is open; the
always-on probe drives the bar icon even while closed.

## Remove

```sh
omarchy plugin remove io.github.p3lu.wg-omarchy-nmcli
# optional: remove the imported NM connection
nmcli connection delete wg0
```

## Troubleshooting

- **Icon dimmed, panel says "No connection found"** — NetworkManager has no
  connection named `connectionName`. Set `configFile` and use **Import config**,
  or fix `connectionName`.
- **Toggle fails** — the connection exists but `up` failed; run
  `nmcli connection up wg0` in a terminal for the error.
- **Config path with `~`** — the widget expands a leading `~/` to your home
  directory before invoking the import, so `~/.config/wireguard/wg0.conf` works.
- **Debug logs** — `qs log -p "$OMARCHY_PATH/shell" --tail 100`.

## License

MIT — see [LICENSE](LICENSE).
