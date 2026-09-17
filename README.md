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
- **Connect / Disconnect** button and **Import config** action
- **Import config** is shown only while NetworkManager has no connection for
  the tunnel yet (once a profile is loaded there is nothing to import). It
  resolves the source as: your `configFile` setting →
  `~/.config/wireguard/<name>.conf` → `/etc/wireguard/<name>.conf`. Configs
  under `/etc/wireguard/` (0700, root-only) are copied through `pkexec`,
  which raises Omarchy's themed polkit auth dialog — the same pattern the
  built-in Tailscale panel uses. The connection name and the privileged
  source path are strictly validated before any privileged read (see
  [Security](#security)).
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

**Automatic dependency check.** On every status poll the widget probes, as the
user (no privilege escalation), whether it can actually run WireGuard:

- **NetworkManager running** and **kernel module** (loaded, or loadable via a
  dry-run `modprobe -n`) — both are required. If either is missing the panel
  shows a red banner with the reason and, where the distro has a single
  canonical package, the install command (e.g. `sudo apt install wireguard`).
  The **Connect tunnel** button is dimmed and refuses to act, so you are never
  left with a silent `nmcli` failure.
- **`wg` from wireguard-tools** — optional. Only while the tunnel is up does a
  missing `wg` matter, and it only degrades the *Last handshake* cell, so the
  panel shows a quiet note (with `sudo pacman -S wireguard-tools` /
  `sudo apt install wireguard-tools` etc.) instead of a hard error.

The probe runs on every poll and re-checks automatically: install the missing
package and the banner clears on the next poll (a few seconds) without a
restart.

## Usage

The widget polls NetworkManager for a wireguard connection named `wg0`
(default). The icon is bright when connected, dimmed when the connection is
unknown.

| Action | Effect |
|---|---|
| Left-click (icon) | Open / close the panel |
| **Connect / Disconnect** | `nmcli connection up wg0` / `nmcli connection down wg0` |
| **Import config** | Stage the `.conf` into a private temp file, delete any existing profile with the same name, then `nmcli connection import type wireguard file …` (via `pkexec` for `/etc/wireguard/` sources) |

### Importing your wg0.conf

The **Import config** button is only visible while no `wg0` profile is loaded
in NetworkManager.

1. (Optional) Set `configFile` — e.g. `~/.config/wireguard/wg0.conf`.
   Without it the widget probes `~/.config/wireguard/<name>.conf` (readable as
   your user) and, failing that, `/etc/wireguard/<name>.conf`.
2. Open the panel and click **Import config**. For `/etc/wireguard/` sources
   Omarchy's themed polkit dialog asks for your password (the config lives in
   a 0700 root-only directory the widget cannot read directly).
3. The import **replaces** an existing profile of the same name: `nmcli` does
   *not* reject duplicate connection names — it would silently add a second
   `wg0` — so any profile with that exact name is deleted before importing.
   No other profile is ever touched.
4. Click **Connect tunnel** (or let it auto-connect — imported profiles
   default to `autoconnect=yes`).

The private key is staged into a `0700` `mktemp` directory and removed on
exit (`trap`), so it never lingers on disk. If the import fails, the first
line of the `nmcli` error is shown on the button (e.g. a malformed config),
along with these transient labels: *Authorizing…* / *Importing…* while
running, and *Authorization cancelled* / *Authentication failed* / *No .conf
found in /etc/wireguard* / *Import failed: …* on error.

Manual equivalent (from a terminal):

```sh
# user-readable config:
nmcli connection import type wireguard file ~/.config/wireguard/wg0.conf
# /etc/wireguard config (needs root; nmcli requires the file to be named <iface>.conf):
sudo cp /etc/wireguard/wg0.conf /tmp/wg0.conf && nmcli connection import type wireguard file /tmp/wg0.conf && rm /tmp/wg0.conf
```

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

## Security

The **Import config** action reads a file that may live in a root-only
directory (`/etc/wireguard/`, mode `0700`) and runs a privileged copy through
`pkexec`. Because that crosses a privilege boundary, the plugin applies the
following controls so that only the intended WireGuard config can ever be
read as root. These close the two findings reported against the import path
(any `/etc/wireguard/`-prefixed string treated as privileged without
canonicalisation, and the connection name used as a pathname component
without validation).

1. **Connection name allowlist.** `connectionName` is accepted only when it
   matches `^[A-Za-z0-9._-]+$` and is non-empty, ≤ 128 chars, and contains no
   path separator, backslash, `..`, or leading dot. The name is used both as
   the staged `<name>.conf` filename and as a literal inside `nmcli`/`grep`,
   so it is validated in QML *and* re-validated in the shell before anything
   runs. Anything else aborts with *Invalid connection name* and never reaches
   a process — let alone a privileged one.
2. **Privileged source built from the validated name, not taken as input.**
   The only source read via `pkexec` is the conventional
   `/etc/wireguard/<name>.conf`, constructed from the validated name. It is
   therefore canonical and bounded by construction: it cannot contain `../`
   or alias (symlink) out of the `0700` directory. The `configFile` setting is
   **never** treated as a privileged path — it is imported directly as the
   user, which is exactly what it is (a user-readable file).
3. **No-follow guard in the shell.** Before the privileged `cat`, the script
   requires `$src` to be *exactly* `/etc/wireguard/<name>.conf` and refuses a
   symlink at that path. Any traversal, extra segment, or alias is rejected
   (exit 101) before the privileged read is invoked.

The staged copy uses `cat > staged` (a `pkexec`-ed `cp` would leave the staged
file root-owned); the staging dir is a `0700` `mktemp` removed on exit via
`trap`, so the WireGuard private key never lingers.

Exit codes: `0` ok · `126` auth cancelled · `127` not authorized · `101`
source missing/rejected · `103` import failed · `104` invalid connection name.

**Automated security baseline.** `tests/security.sh` extracts the *exact* bash
command shipped in `Widget.qml` and runs it against an isolated mock
environment (no real privilege escalation, no real `/etc`), asserting that
valid inputs succeed and that traversal, symlink-alias, and shell-metacharacter
inputs are refused. It is reproducible and self-contained:

```sh
bash tests/security.sh
# -> SECURITY_BASELINE: PASS (13/13)
```

The same allowlist is unit-tested for the QML layer in
`tests/validname.test.js`:

```sh
node tests/validname.test.js
# -> RESULT ok=15 bad=0
```

`Widget.qml` is also validated with the real Qt 6 parser (`qmllint`), which
reports **zero errors**; the only diagnostics are warnings for the Omarchy
bar-runtime symbols (`qs.Commons`, `qs.Ui`, `bar`, `Style`, …) that are not
present outside the bar, so they are expected in a bare linter environment:

```sh
/usr/lib/qt6/bin/qmllint Widget.qml   # exit 0, no Error lines
```

## Update lifecycle (important)

Omarchy compiles each bar-widget entry point **once** and caches the
`Component` keyed by its file URL. An in-place `omarchy plugin update <id>`
that keeps the same entry-point filename (`Widget.qml`) will **not**
recompile the QML on rescan — the old compiled component keeps serving
(Quickshell also caches compiled QML under
`~/.cache/quickshell/qmlcache/`). A rescan can report success while the
running shell still executes the *previous* code.

**After updating this plugin, always run `omarchy restart shell`.** If you
ever see symptoms of stale QML (old errors in the log, new UI missing):

```sh
rm -rf ~/.cache/quickshell/qmlcache/*
omarchy restart shell
```

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
  connection named `connectionName`. That is also when the **Import config**
  button appears: set `configFile` (if your config is elsewhere) and use
  **Import config**, or fix `connectionName`.
- **Import config says "Authorization cancelled"** — you dismissed the polkit
  dialog. Click the button and complete the dialog.
- **Import config says "Authentication failed"** — the password entered in
  the polkit dialog was rejected (the `pkexec` policy requires admin).
- **Import config says "No .conf found in /etc/wireguard"** — no
  `/etc/wireguard/<name>.conf` exists and no user-readable config was found;
  set `configFile`.
- **Import config says "Import failed: …"** — `nmcli` rejected the config
  (malformed, wrong file name, …); the first error line is shown on the
  button.
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
