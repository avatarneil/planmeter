# planmeterd on Linux

`planmeterd` is PlanMeter's headless host. It reads the same transcripts the
Mac app does (`~/.codex`, `~/.claude`, `$XDG_DATA_HOME/opencode`, T3 Code) and
serves:

- the **control API** on a Unix socket, for desktop UIs (the GTK app), and
- when remote access is on, the **end-to-end encrypted API** that the iPhone,
  Android, and web clients use over Tailscale.

See [docs/cross-platform.md](../../docs/cross-platform.md) for the design and
the control API reference.

## Build and install

```sh
swift build -c release --product planmeterd
install -Dm755 .build/release/planmeterd ~/.local/bin/planmeterd
# Optional: the web client, served at https://<machine>.<tailnet>.ts.net/
mkdir -p ~/.local/share/planmeter && cp -R Sources/PlanMeter/Web ~/.local/share/planmeter/web
```

## Run as a user service

```sh
install -Dm644 packaging/linux/planmeterd.service ~/.config/systemd/user/planmeterd.service
systemctl --user daemon-reload
systemctl --user enable --now planmeterd
journalctl --user -u planmeterd -f
```

On a server without a desktop session, `loginctl enable-linger "$USER"` keeps
the service running after you log out.

## Files

| What | Where |
| --- | --- |
| Settings (groups, spend limits, remote access) | `$XDG_CONFIG_HOME/planmeter/settings.json` (`~/.config/planmeter`) |
| Scan cache, pricing cache | `$XDG_STATE_HOME/planmeter/` (`~/.local/state/planmeter`) |
| Paired devices, server key (0600) | `$XDG_STATE_HOME/planmeter/remote/` |
| Control socket (0600, same user only) | `$XDG_RUNTIME_DIR/planmeter/control.sock` |

## Remote access

Remote access is off until you turn it on. It listens only on this machine's
Tailscale addresses (never `0.0.0.0`), refuses peers outside the tailnet, and
every request is encrypted to this host's key and signed by a paired device.

```sh
SOCK="$XDG_RUNTIME_DIR/planmeter/control.sock"
curl --unix-socket "$SOCK" -X PUT http://localhost/v1/remote -d '{"enabled": true}'
curl --unix-socket "$SOCK" -X POST http://localhost/v1/remote/invite   # pairing link + web code
```

Or run once with `planmeterd --remote --pairing-link` to print a pairing link.
The link is a secret for five minutes; scan it as a QR code (for example
`qrencode -t ansiutf8 'planmeter://pair?…'`) or open it on the phone.

For the web client over HTTPS, let your user drive `tailscale serve`
(`sudo tailscale set --operator=$USER`) and enable it with
`{"httpsEnabled": true}`. That also binds `127.0.0.1`, which Tailscale Serve
proxies to.

## Useful flags

`--socket PATH`, `--port N`, `--remote` / `--no-remote` (this run only),
`--loopback` (also listen on 127.0.0.1, for local testing), `--pairing-link`,
`--offline` (no pricing refresh or Codex account-wide readings),
`--web-dir DIR`, `--config-dir DIR`, `--state-dir DIR`. Run
`planmeterd --help` for the full list.
