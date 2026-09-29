# Bogger
A small bash utility that analyzes Nginx access logs and identifies anomalies


[![AGPL License](https://img.shields.io/badge/license-AGPL-blue.svg)](http://www.gnu.org/licenses/agpl-3.0)

## Usage

``` bash
./bogger <NGINX_LOGFILE>
```
The script will fail to run if the file is not a valid Nginx access log file. You can change `NGINX_LOGFILE` variable inside of the script to match the one you are using on your nginx server. The default filename is `nginx-access.log`.

## TODO
- Add a simple AI analysis and summary
- Notify user on anomalies and issues
- Add systemd service to check at specified intervals and email the user
