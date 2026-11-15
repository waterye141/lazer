# Lazer

Lazer is a Bash utility that summarizes server logs and optionally sends the summary and recent records to OpenRouter for anomaly analysis, with optional Groq fallback.

[![AGPL License](https://img.shields.io/badge/license-AGPL-blue.svg)](http://www.gnu.org/licenses/agpl-3.0)

## Requirements

Lazer requires the following dependencies:

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
chmod +x lazer.sh
```

For remote analysis, copy the local dotenv template and add an OpenRouter key:

```bash
cp .env.example .env
$EDITOR .env
```

## Interactive use

Run Lazer without `--service` to open the menu:

```bash
./lazer.sh
```

The menu options are:

1. **Install lazer to PATH** — copies Lazer to `/usr/bin/lazer` and installs its parser module.
2. **View local statistics (choose service)** — asks which supported service to analyze, then reads the selected log locally and displays statistics.
3. **Run AI anomaly analysis (choose service)** — asks which supported service to analyze, then sends its summary to the configured AI provider and prints the findings.
4. **Install systemd service to notify on anomalies** — installs and enables the hourly service and timer.
5. **Remove lazer from your system** — disables the timer and removes installed Lazer files while preserving `/etc/lazer/lazer.env`.

For options 2 and 3, Lazer first asks whether to analyze Nginx, Apache, SSH/authentication, the systemd journal, HAProxy, Docker, or a generic application log. It then asks for the relevant log path, except for Nginx where the path may be left blank for automatic discovery and systemd journal where optional `journalctl` filters can be entered. Option 2 also asks how many top results to display.

## Command-line use

Show the available flags:

```bash
./lazer.sh --help
```

The general form is:

```bash
./lazer.sh --source SOURCE --file PATH
```

The original positional Nginx form remains supported:

```bash
./lazer.sh /var/log/nginx/access.log
```

Available flags:

| Flag | Purpose |
| --- | --- |
| `--stats` | Run local statistics directly using the selected parser. |
| `--analyze` | Run AI anomaly analysis directly using the selected parser. |
| `--source SOURCE` | Select `nginx`, `apache`, `ssh`, `systemd_journal`, `haproxy`, `docker`, or `generic`. |
| `--file PATH` | Select a file for file-based sources. |
| `--unit UNIT` | Restrict `systemd_journal` input to a systemd unit. |
| `--since TIME` | Restrict journal input to a start time such as `today`. |
| `--until TIME` | Restrict journal input to an end time. |
| `--service` | Run once without prompts using `/etc/lazer/lazer.env`; used by systemd. |

When `--source` or `--file` is supplied without `--stats` or `--analyze`, Lazer displays a two-option prompt for local statistics or AI analysis and then dispatches the selected parser. If neither action flag nor source/file arguments are supplied, the full installation and service menu is shown. `systemd_journal` requires an explicit `--stats` or `--analyze` action.

### Shell completion

Menu option `1` installs system-wide Bash and Zsh completions:

- Bash: `/etc/bash_completion.d/lazer`
- Zsh: `/usr/share/zsh/site-functions/_lazer`

Start a new shell, or reload the completion file in an existing Bash session:

```bash
source /etc/bash_completion.d/lazer
```

The completions cover actions, flags, supported source names, common journal time values, and filesystem paths after `--file`. For a checkout without installing Lazer, load the Bash completion manually:

```bash
source completions/lazer.bash
```

Zsh users can load the checkout completion by adding the repository's `completions` directory to `fpath` and autoloading `_lazer`:

```zsh
fpath=(./completions $fpath)
autoload -Uz _lazer
compinit
```

Examples:

```bash
./lazer.sh --stats --source apache --file /var/log/apache2/access.log
./lazer.sh --analyze --source ssh --file /var/log/auth.log
./lazer.sh --stats --source systemd_journal --unit ssh.service --since today
```

Reports use the same categories as the original Nginx analyzer: top client IPs, requested paths or targets, response status codes, and user agents. Sources that do not provide a category show `N/A`.

## Supported log sources

### Nginx

Lazer can discover Nginx’s first configured `access_log`, fall back to `/var/log/nginx/access.log`, or use an explicit path:

```bash
./lazer.sh --source nginx --file /var/log/nginx/access.log
```

### Apache

Debian-based systems commonly use:

```bash
./lazer.sh --source apache --file /var/log/apache2/access.log
```

Rocky Linux commonly uses:

```bash
./lazer.sh --source apache --file /var/log/httpd/access_log
```

### SSH/authentication logs

Debian-based systems commonly use:

```bash
./lazer.sh --source ssh --file /var/log/auth.log
```

Rocky Linux commonly uses:

```bash
./lazer.sh --source ssh --file /var/log/secure
```

### systemd journal

Use `journalctl` through the journal source instead of providing a file:

```bash
./lazer.sh --source systemd_journal --unit ssh.service --since today
```

Other useful filters include `--until`, for example:

```bash
./lazer.sh --source systemd_journal --since yesterday --until today
```

### HAProxy

```bash
./lazer.sh --source haproxy --file /var/log/haproxy.log
```

### Docker

Select a Docker JSON log file:

```bash
./lazer.sh --source docker --file /var/lib/docker/containers/CONTAINER_ID/CONTAINER_ID-json.log
```

Docker reports include stdout/stderr streams, application severity, lifecycle/health/dependency/OOM signals, and HTTP method/path/status fields when the message contains an HTTP access line. To include optional runtime metadata such as image, restart count, CPU, memory, network I/O, block I/O, and PID count, set `LAZER_DOCKER_CONTAINER` to a container name or ID. The Docker CLI is optional; log parsing continues without it.

### Generic logs

Use the generic parser for timestamped or plain-text application logs:

```bash
./lazer.sh --source generic --file /var/log/my-service/application.log
```

## Source-specific analysis

Reports retain the common source, severity, client, path, status, and user-agent sections and add specialized indicators:

- **Nginx/Apache:** status classes, HTTP methods, referrers, and request-focused error concentration.
- **SSH/authentication:** authentication outcomes, usernames, source IPs, ports, and privilege-use events.
- **systemd journal:** units, severity distribution, and failure, OOM, and lifecycle signals.
- **HAProxy:** backend concentration, HTTP statuses, and termination states.
- **Docker:** streams, lifecycle/health/dependency/OOM events, HTTP fields, and optional runtime metadata.
- **Generic:** severity distribution and detected error concentration.

The specialized fields are also included in AI analysis context. Docker json-file logs are daemon-managed files; avoid modifying them directly while Docker is running.

## AI analysis and provider fallback

OpenRouter is the primary provider and requires `OPENROUTER_API_KEY`. Groq is optional and is attempted when OpenRouter fails, returns no usable content, or returns an invalid analysis response.

The default models are:

- OpenRouter: `openrouter/free`
- Groq: `openai/gpt-oss-120b`

For local runs, the OpenRouter key is read from `.env`. Other provider settings can be exported before starting Lazer:

```bash
export GROQ_API_KEY='your-groq-key'
export OPENROUTER_MODEL='openrouter/free'
export GROQ_MODEL='openai/gpt-oss-120b'
./lazer.sh --source nginx --file /var/log/nginx/access.log
```

The providers must return:

```json
{"anomaly": true, "findings": "description of the finding"}
```

## Systemd service

Select menu option `4` to install the system-wide hourly timer and service. The installer:

1. Copies Lazer to `/usr/bin/lazer`.
2. Installs the parser module under `/usr/share/lazer`.
3. Installs `lazer.service` and `lazer.timer`.
4. Creates `/etc/lazer/lazer.env` from the example if it does not already exist.
5. Reloads systemd and enables the hourly timer.

Edit the environment file before relying on the service:

```bash
sudo editor /etc/lazer/lazer.env
```

Important settings:

```dotenv
OPENROUTER_API_KEY=
GROQ_API_KEY=
OPENROUTER_MODEL=openrouter/free
GROQ_MODEL=openai/gpt-oss-120b
LAZER_SOURCE=nginx
LOG_FILE=
LAZER_INPUT_FILE=
LAZER_JOURNALCTL_ARGS=
LAZER_EMAIL_RECIPIENT=
LAZER_MAIL_COMMAND=/usr/bin/mail
```

Use `LAZER_SOURCE` and `LAZER_INPUT_FILE` to select a non-Nginx file source. For journal input, leave the file variables empty and set journal filters, for example:

```dotenv
LAZER_SOURCE=systemd_journal
LAZER_JOURNALCTL_ARGS=--unit ssh.service --since today
```

The service runs once per hour:

```bash
sudo systemctl status lazer.timer
sudo systemctl status lazer.service
sudo journalctl -u lazer.service
```

To run the service path immediately:

```bash
sudo /usr/bin/lazer --service
```

Lazer logs each run to the journal and sends email only when the validated response sets `anomaly` to `true`. Configure `LAZER_EMAIL_RECIPIENT` and a working `LAZER_MAIL_COMMAND` before expecting email notifications.

To remove the installed service and executable, select menu option `5`. The removal keeps `/etc/lazer/lazer.env` so configuration is not lost.
