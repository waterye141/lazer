# Bogger

Bogger is a Bash utility that summarizes server logs and optionally sends the summary and recent records to OpenRouter for anomaly analysis, with optional Groq fallback.

[![AGPL License](https://img.shields.io/badge/license-AGPL-blue.svg)](http://www.gnu.org/licenses/agpl-3.0)

## Requirements

Bogger requires the following dependencies:

- Bash
- `curl`
- `jq`
- `awk`, `grep`, `sed`, `sort`, `uniq`, `head`, and `tail`

Additional requirements:

- `journalctl` when reading `systemd_journal` input.
- `sudo` and systemd when installing the system service.
- A `mail`/`mailx`-compatible command when sending anomaly email.

## Local setup

Clone or copy the repository, then make the entry point executable:

```bash
chmod +x bogger.sh
```

For remote analysis, copy the local environment template and add an OpenRouter key:

```bash
cp .env.example .env
$EDITOR .env
```

`.env` is ignored by Git. Do not commit API keys.

## Interactive use

Run Bogger without `--service` to open the menu:

```bash
./bogger.sh
```

The menu options are:

1. **Install bogger to PATH** — copies Bogger to `/usr/bin/bogger` and installs its parser module.
2. **Raw analysis** — reads the selected log locally and displays statistics.
3. **Get a summary regarding the logs read** — sends the selected log summary to the configured AI provider and prints the findings.
4. **Install systemd service to notify on anomalies** — installs and enables the hourly service and timer.
5. **Remove bogger from your system** — disables the timer and removes installed Bogger files while preserving `/etc/bogger/bogger.env`.

For options 2 and 3, Bogger asks how many top results to display when the selected parser supports a result count.

## Command-line use

Show the available flags:

```bash
./bogger.sh --help
```

The general form is:

```bash
./bogger.sh --source SOURCE --file PATH
```

The original positional Nginx form remains supported:

```bash
./bogger.sh /var/log/nginx/access.log
```

Available flags:

| Flag | Purpose |
| --- | --- |
| `--source SOURCE` | Select `nginx`, `apache`, `ssh`, `systemd_journal`, `haproxy`, `docker`, or `generic`. |
| `--file PATH` | Select a file for file-based sources. |
| `--unit UNIT` | Restrict `systemd_journal` input to a systemd unit. |
| `--since TIME` | Restrict journal input to a start time such as `today`. |
| `--until TIME` | Restrict journal input to an end time. |
| `--service` | Run once without prompts using `/etc/bogger/bogger.env`; used by systemd. |

Reports use the same categories as the original Nginx analyzer: top client IPs, requested paths or targets, response status codes, and user agents. Sources that do not provide a category show `N/A`.

## Supported log sources

### Nginx

Bogger can discover Nginx’s first configured `access_log`, fall back to `/var/log/nginx/access.log`, or use an explicit path:

```bash
./bogger.sh --source nginx --file /var/log/nginx/access.log
```

### Apache

Debian-based systems commonly use:

```bash
./bogger.sh --source apache --file /var/log/apache2/access.log
```

Rocky Linux commonly uses:

```bash
./bogger.sh --source apache --file /var/log/httpd/access_log
```

### SSH/authentication logs

Debian-based systems commonly use:

```bash
./bogger.sh --source ssh --file /var/log/auth.log
```

Rocky Linux commonly uses:

```bash
./bogger.sh --source ssh --file /var/log/secure
```

### systemd journal

Use `journalctl` through the journal source instead of providing a file:

```bash
./bogger.sh --source systemd_journal --unit ssh.service --since today
```

Other useful filters include `--until`, for example:

```bash
./bogger.sh --source systemd_journal --since yesterday --until today
```

### HAProxy

```bash
./bogger.sh --source haproxy --file /var/log/haproxy.log
```

### Docker

Select a Docker JSON log file:

```bash
./bogger.sh --source docker --file /var/lib/docker/containers/CONTAINER_ID/CONTAINER_ID-json.log
```

### Generic logs

Use the generic parser for timestamped or plain-text application logs:

```bash
./bogger.sh --source generic --file /var/log/my-service/application.log
```

## AI analysis and provider fallback

OpenRouter is the primary provider and requires `OPENROUTER_API_KEY`. Groq is optional and is attempted when OpenRouter fails, returns no usable content, or returns an invalid analysis response.

The default models are:

- OpenRouter: `openrouter/free`
- Groq: `openai/gpt-oss-120b`

For local runs, the OpenRouter key is read from `.env`. Other provider settings can be exported before starting Bogger:

```bash
export GROQ_API_KEY='your-groq-key'
export OPENROUTER_MODEL='openrouter/free'
export GROQ_MODEL='openai/gpt-oss-120b'
./bogger.sh --source nginx --file /var/log/nginx/access.log
```

The providers must return:

```json
{"anomaly": true, "findings": "description of the finding"}
```

## Systemd service

Select menu option `4` to install the system-wide hourly timer and service. The installer:

1. Copies Bogger to `/usr/bin/bogger`.
2. Installs the parser module under `/usr/share/bogger`.
3. Installs `bogger.service` and `bogger.timer`.
4. Creates `/etc/bogger/bogger.env` from the example if it does not already exist.
5. Reloads systemd and enables the hourly timer.

Edit the environment file before relying on the service:

```bash
sudo editor /etc/bogger/bogger.env
```

Important settings:

```dotenv
OPENROUTER_API_KEY=
GROQ_API_KEY=
OPENROUTER_MODEL=openrouter/free
GROQ_MODEL=openai/gpt-oss-120b
BOGGER_SOURCE=nginx
LOG_FILE=
BOGGER_INPUT_FILE=
BOGGER_JOURNALCTL_ARGS=
BOGGER_EMAIL_RECIPIENT=
BOGGER_MAIL_COMMAND=/usr/bin/mail
```

Use `BOGGER_SOURCE` and `BOGGER_INPUT_FILE` to select a non-Nginx file source. For journal input, leave the file variables empty and set journal filters, for example:

```dotenv
BOGGER_SOURCE=systemd_journal
BOGGER_JOURNALCTL_ARGS=--unit ssh.service --since today
```

The service runs once per hour:

```bash
sudo systemctl status bogger.timer
sudo systemctl status bogger.service
sudo journalctl -u bogger.service
```

To run the service path immediately:

```bash
sudo /usr/bin/bogger --service
```

Bogger logs each run to the journal and sends email only when the validated response sets `anomaly` to `true`. Configure `BOGGER_EMAIL_RECIPIENT` and a working `BOGGER_MAIL_COMMAND` before expecting email notifications.

To remove the installed service and executable, select menu option `5`. The removal keeps `/etc/bogger/bogger.env` so configuration is not lost.
