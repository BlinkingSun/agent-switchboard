# Running the daemon at login

The daemon is read-only and binds 127.0.0.1 only.

## macOS (launchd)

Edit `com.agent-switchboard.plist` — replace `/PATH/TO/REPO` with your clone
path — then:

```bash
cp com.agent-switchboard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agent-switchboard.plist
curl -s http://127.0.0.1:17920/v1/health
```

## Linux (systemd user unit)

`~/.config/systemd/user/agent-switchboard.service`:

```ini
[Unit]
Description=Agent Switchboard daemon

[Service]
ExecStart=/usr/bin/python3 /PATH/TO/REPO/bin/switchboard serve --port 17920
Restart=always

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now agent-switchboard
```

## Windows (Task Scheduler)

```powershell
schtasks /Create /TN "Agent Switchboard" /SC ONLOGON /TR ^
  "py -3 C:\PATH\TO\REPO\bin\switchboard serve --port 17920"
```
