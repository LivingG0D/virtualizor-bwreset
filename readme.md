# Virtualizor Bandwidth Carry-Over Manager

A user-friendly, menu-driven command-line tool to automate the process of resetting and carrying over unused bandwidth for Virtualizor-based VPSs. This script allows you to manage the entire process, from configuration to manual runs and cron job automation, through a simple interface.

**Created by LivingGOD**

<img width="822" height="451" alt="image_2025-07-28_00-34-27" src="https://github.com/user-attachments/assets/f3b14d29-bd32-4587-b139-75757c1c1bc8" />

## ✨ Features

* **All-in-One Interface:** Manage configuration, manual resets, and automation from a single command.

* **Dedicated Configuration:** Safely stores your API credentials in `/etc/vps_manager.conf`.

* **Intelligent Carry-Over:** Calculates unused bandwidth and applies it as the new limit for the next billing cycle.

* **Flexible Targeting:** Reset bandwidth for a single VPS or all servers on the node.

* **Full Automation:** Easily set up, view, and remove daily or monthly cron jobs.

* **Safe & Robust:** Includes dependency checks, robust error handling, and detailed logging to `/tmp/reset_band.log`.

## 🚀 Installation

Use one of the following one-line commands to download the script to `/root/`, make it executable, and run it for the first time.

**Using `wget`:**
```
wget -O /root/vps_manager.sh \
  https://github.com/LivingG0D/virtualizor-bwreset/releases/download/0.2/reset_band.sh && \
chmod +x /root/vps_manager.sh && \
/root/vps_manager.sh

```

**Using `curl`:**
```
curl -L -o /root/vps_manager.sh \
  https://github.com/LivingG0D/virtualizor-bwreset/releases/download/0.2/reset_band.sh && \
chmod +x /root/vps_manager.sh && \
/root/vps_manager.sh

```

## ⚙️ First-Time Setup

The first time you run the script, it will automatically create a configuration file at `/etc/vps_manager.conf`.

1. Run the script: `/root/vps_manager.sh`

2. Select **1. Configure Script** from the main menu.

3. Enter your Virtualizor Host IP, API Key, and API Password.

Your credentials are now saved, and you can proceed to use the other script features.

## 🔧 Usage

* **Configure:** Edit your API credentials.

* **Manual Reset:** Immediately run the bandwidth carry-over for all servers or a specific VPS ID. The results of the operation will be displayed on screen.

* **Manage Automation:**

  * Enable a daily or monthly cron job.

  * Disable and remove any existing cron job set by this script.

  * View the current status of the cron job.

  * Manually edit your crontab file using the `nano` editor.

## 📝 Logging

The script generates two log files in the `/tmp/` directory for easy debugging and auditing:

* `/tmp/reset_band.log`: A detailed, verbose log of all actions.

* `/tmp/reset_band_changes.log`: A clean audit log that only contains entries for successfully processed servers.
## 📜 License

This project is licensed under the MIT License.
