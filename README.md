# Bogger
A small bash utility that analyzes Nginx access logs and identifies anomalies


[![AGPL License](https://img.shields.io/badge/license-AGPL-blue.svg)](http://www.gnu.org/licenses/agpl-3.0)

## Usage

``` bash
./bogger.sh <NGINX_LOGFILE>
```
The script will fail to run if the file is not a valid Nginx access log file. You can change `NGINX_LOGFILE` variable inside of the script to match the one you are using on your nginx server.

You can use you own API key by renaming the `.env.example` to `.env` and simply adding it to the file.

Bogger accepts explicit source selection for `nginx`, `apache`, `ssh`, `systemd_journal`, `haproxy`, `docker`, and `generic` logs:

```bash
./bogger.sh --source apache --file /var/log/httpd/access_log
./bogger.sh --source ssh --file /var/log/auth.log
./bogger.sh --source systemd_journal --unit ssh.service --since today
```

The report keeps the original Nginx categories—top client IPs, requested paths or targets, response status codes, and user agents. Parsers populate equivalent fields when the source provides them and show `N/A` when a category is not present in that log format.

## Systemd service

Select option `4` from the menu to install the system-wide hourly timer and service. The installer copies the executable to `/usr/bin/bogger`, installs the units, and creates `/etc/bogger/bogger.env` from the example if it does not exist.

Edit `/etc/bogger/bogger.env` before relying on the timer:

- `OPENROUTER_API_KEY` is required and OpenRouter is always tried first.
- `GROQ_API_KEY` is optional; Groq is used as a fallback when OpenRouter has a network/HTTP error, empty response, or invalid analysis response.
- `OPENROUTER_MODEL` defaults to `openrouter/free`.
- `GROQ_MODEL` defaults to `openai/gpt-oss-120b`.
- `OPENROUTER_API_URL` and `GROQ_API_URL` are configurable for compatible endpoints.
- `LOG_FILE` is optional; when empty, Bogger uses its existing Nginx log discovery.
- `BOGGER_EMAIL_RECIPIENT` is required for anomaly email.
- `BOGGER_MAIL_COMMAND` should point to a `mail`/`mailx`-compatible executable.

The service runs `bogger --service` hourly, writes output and errors to the journal, and sends mail only when a validated provider response sets `anomaly` to `true`. Inspect it with `systemctl status bogger.timer`, `systemctl status bogger.service`, or `journalctl -u bogger.service`.

Groq model access and quotas depend on the account and plan; model IDs remain configurable so the fallback can be updated independently of the script.

To run the unattended path once without waiting for the timer:

```bash
sudo /usr/bin/bogger --service
```

Selecting option `5` stops/disables the timer and removes the installed unit files and executable; it leaves `/etc/bogger/bogger.env` in place so configuration is not lost.
