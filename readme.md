# Virtualizor Bandwidth Carry-Over Manager

A menu-driven command-line tool that resets bandwidth usage for Virtualizor VPSs and carries the unused quota over into each VPS's limit. Configuration, manual runs and cron automation all live in one script.

**Created by LivingGOD**

<img width="822" height="451" alt="image_2025-07-28_00-34-27" src="https://github.com/user-attachments/assets/f3b14d29-bd32-4587-b139-75757c1c1bc8" />

## ✨ Features

* **All-in-one interface:** configuration, manual resets and automation from a single command.
* **Carry-over:** for each VPS, usage is reset to 0 and the limit becomes `limit - used`, so only the unused quota remains. The VPS keeps its plan ID.
* **Fast:** VPSs are processed in parallel (5 at a time by default).
* **Safe:** a dry run shows every change before you make one. A lock stops two runs from overlapping. The API credentials are stored with mode `600` and never appear in the process list.
* **Targeting:** reset all VPSs on the master, or a single VPS ID.
* **Automation:** daily, monthly or last-day-of-month cron jobs.

### Carry-over rules

| Plan limit | What happens |
|---|---|
| `0` (unlimited) | Usage is reset. The limit stays `0`. |
| Positive, usage < limit | Usage is reset. The new limit is `limit - used`. |
| Positive, usage ≥ limit | The VPS is skipped and logged as `SKIPPED`. A new limit of `0` would make it unlimited. |
| Negative | Usage is reset. The new limit is `limit + used`, which moves it towards zero. |

Usage is rounded down to whole GB. A VPS whose `bandwidth`, `used_bandwidth` or `plid` is missing or not a number is skipped and reported as an error.

## ✅ Compatibility

* Virtualizor **3.3.0** and later, using the Admin API on port `4085`. The calls match Virtualizor's current documentation and official PHP SDK: `act=vs` (list, 1-based `page`/`reslen` paging), `act=vs&bwreset=ID`, and `act=managevps` with `editvps=1&theme_edit=1`.
* Linux with `bash` 4+, `curl`, `jq` 1.5+, `whiptail` (menu only), `flock` and `cron`.

Install the dependencies:

```bash
apt install -y curl jq whiptail     # Debian / Ubuntu
dnf install -y curl jq newt         # AlmaLinux / Rocky
```

## 🚀 Installation

Download the script to `/root/`, make it executable, and run it:

```bash
curl -fL -o /root/vps_manager.sh https://raw.githubusercontent.com/LivingG0D/virtualizor-bwreset/refs/heads/main/reset_band.sh && chmod +x /root/vps_manager.sh && /root/vps_manager.sh
```

To update, run the same command again. Your configuration and cron job are kept.

## 🔑 API credentials

Since Virtualizor 3.1, API credentials have their own ACL and IP whitelist. In the admin panel, open **API Credentials** and click **Create API Credential**. Give the key access to:

* listing virtual servers,
* resetting bandwidth,
* editing VMs (**Edit VM**).

If you use an IP whitelist, add the IP of the machine that runs this script. You can also use the master key from **Configuration → Server Info**.

## ⚙️ First-time setup

The first run creates `/etc/vps_manager.conf`.

1. Run the script: `/root/vps_manager.sh`
2. Choose **Configure**.
3. Enter the master's IP or hostname, the API key, the API password and the number of parallel jobs. Later, leave the key or password blank to keep the stored one.

The host can include a port (`panel.example.com:4085`) or a scheme (`http://10.0.0.5:4084` for the non-SSL port). Without them, `https://HOST:4085` is used. To use a full URL instead, set `API_BASE` in the config file.

Then check what a reset would do before you change anything:

```bash
/root/vps_manager.sh --dry-run
```

## 🔧 Usage

Interactive menu (`/root/vps_manager.sh`):

* **Configure:** edit the host, credentials and parallel jobs.
* **Manual Reset:** reset all VPSs, reset one VPS ID, or do a dry run. The results are shown on screen.
* **Automation:** enable a daily (00:00), monthly (1st, 02:00) or last-day-of-month (23:30) cron job, disable it, or edit the crontab. The menu shows the current job.

Command-line options:

| Option | What it does |
|---|---|
| `--cron` | Reset all VPSs and append the output to the log. The cron job runs this. |
| `--dry-run [ID]` | Show what a reset of all VPSs, or of one VPS ID, would change. Changes nothing. |
| `--list-vps` | List the VPSs with usage, limit and status. |
| `--help` | Show the help. |

## 📝 Logging

Logs are written to `/root`. Set `DIAG_DIR` to use another directory.

* `/root/reset_band.log`: a detailed log of every run.
* `/root/reset_band_changes.log`: an audit log with one line for each VPS that was changed, skipped, reset on an unlimited plan, or whose limit update failed. For example: `2026-10-19 00:00:01  VPS 101  300/1000 => 0/700 (plan 2)`.

## 🩺 Troubleshooting

* **`Not a JSON API response`**: the host or port is wrong, or the credentials are wrong. The log shows the first 200 characters of the reply.
* **`API error ...`**: Virtualizor rejected the call. Check the key's ACL and IP whitelist.
* **`SSL certificate problem: self-signed certificate`**: the master uses Virtualizor's default certificate. Install a valid certificate on the master. Or, on a trusted network only, use the non-SSL port: `HOST="http://IP:4084"`.
* **`usage reset but limit update failed`**: the usage of that VPS is now 0, but its limit was not lowered. A new run cannot recover the old usage. Set the limit that the log line gives in the panel.

## 🧪 Tests

The tests run the script against a mock Virtualizor API. They need `python3`:

```bash
bash tests/test_reset_band.sh
```

## 📜 License

This project is licensed under the Apache-2.0 License.
