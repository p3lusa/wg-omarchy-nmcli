# WireGuard VPN (wg-omarchy-nmcli)

A WireGuard VPN toggle for the [Omarchy](https://omarchy.org) Quattro bar, driven by
[NetworkManager](https://networkmanager.dev) via `nmcli`. Shows connection state in the
bar, toggles the tunnel on click, and can import your `wg0.conf` into NetworkManager
with a right-click.

## Features

- Bar icon with live WireGuard state (polls every few seconds)
- **Left-click**: connect / disconnect the tunnel
- **Right-click**: import your WireGuard config into NetworkManager (`nmcli connection import`)
- Connection name, poll interval, and config path are configurable per widget
- IPC target: `omarchy-shell shell call io.github.p3lu.wg-omarchy-nmcli status|toggle|refreshStatus|importConfig`

## Install

```sh
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable
# non-interactive (no prompts):
omarchy plugin add https://github.com/p3lusa/wg-omarchy-nmcli.git --enable --yes
```

### Dependencies

- `networkmanager` (and a running NetworkManager — Omarchy ships it)
- `wireguard-tools` (for `wg-quick`/`wg` if you want to inspect the tunnel)
- A WireGuard config file you can read, e.g. `~/.config/wireguard/wg0.conf`

## Usage

The widget polls NetworkManager for an active wireguard connection named
`wg0` (default). The icon is bright when connected, dimmed when the
connection is unknown.

| Action | Effect |
|---|---|
| Left-click | `nmcli connection up wg0` / `nmcli connection down wg0` |
| Right-click | `nmcli connection import type wireguard file <configFile>` |

### Importing your wg0.conf

1. Set the config path (see Configure below) — e.g. `~/.config/wireguard/wg0.conf`.
2. Right-click the bar icon. NetworkManager imports the connection and names it
   after the `[Interface]` section (usually `wg0`), matching the default
   `connectionName`.
3. Left-click to connect.

> If the import fails with "connection already exists", delete the stale one first:
> `nmcli connection delete wg0` — or set a different `connectionName` and rename the
> `[Interface]` section in your config.

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
| `configFile` | string | *(empty)* | Path passed to `nmcli connection import` on right-click. Empty disables right-click import. |

Move the widget to another bar section:

```sh
omarchy bar move io.github.p3lu.wg-omarchy-nmcli --section left
```

## Remove

```sh
omarchy plugin remove io.github.p3lu.wg-omarchy-nmcli
# optional: remove the imported NM connection
nmcli connection delete wg0
```

## Troubleshooting

- **Icon dimmed, clicking does nothing** — NetworkManager has no connection named
  `connectionName`. Import your config (right-click) or fix `connectionName`.
- **Toggle fails** — the connection exists but `up` failed; run
  `nmcli connection up wg0` in a terminal for the error.
- **Config path with `~`** — the widget expands a leading `~/` to your home
  directory before invoking the import, so `~/.config/wireguard/wg0.conf` works.
- **Debug logs** — `qs log -p "$OMARCHY_PATH/shell" --tail 100`.

## License

MIT — see [LICENSE](LICENSE).
