# Bogger
A small bash utility that analyzes Nginx access logs and identifies anomalies


[![AGPL License](https://img.shields.io/badge/license-AGPL-blue.svg)](http://www.gnu.org/licenses/agpl-3.0)

## Usage

``` bash
./bogger.sh <NGINX_LOGFILE>
```
The script will fail to run if the file is not a valid Nginx access log file. You can change `NGINX_LOGFILE` variable inside of the script to match the one you are using on your nginx server.

You can use you own API key by renaming the `.env.example` to `.env` and simply adding it to the file.

## Systemd service

Select option `4` from the menu to install the system-wide hourly timer and service. The installer copies the executable to `/usr/bin/bogger`, installs the units, and creates `/etc/bogger/bogger.env` from the example if it does not exist.

Edit `/etc/bogger/bogger.env` before relying on the timer:

- `OPENROUTER_API_KEY` is required.
- `LOG_FILE` is optional; when empty, Bogger uses its existing Nginx log discovery.
- `BOGGER_EMAIL_RECIPIENT` is required for anomaly email.
- `BOGGER_MAIL_COMMAND` should point to a `mail`/`mailx`-compatible executable.

The service runs `bogger --service` hourly, writes output and errors to the journal, and sends mail only when the structured OpenRouter response sets `anomaly` to `true`. Inspect it with `systemctl status bogger.timer`, `systemctl status bogger.service`, or `journalctl -u bogger.service`.

To run the unattended path once without waiting for the timer:

```bash
sudo /usr/bin/bogger --service
```

Selecting option `5` stops/disables the timer and removes the installed unit files and executable; it leaves `/etc/bogger/bogger.env` in place so configuration is not lost.
