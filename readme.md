# Virtualizor Bandwidth Carry-Over Script

A powerful command-line tool designed to automate the process of resetting and carrying over unused bandwidth for Virtualizor-based VPSs. Instead of simply resetting bandwidth to zero each month, this script calculates the unused data and sets it as the new limit for the next billing cycle, effectively allowing your users to keep what they didn't use.

---

## ➤ Overview

This script interacts with the Virtualizor Admin API to perform a "carry-over" bandwidth reset. For each targeted VPS, it:
1.  Fetches the current month's bandwidth statistics (limit and usage).
2.  Calculates the remaining (unused) bandwidth.
3.  Resets the bandwidth usage counter to zero.
4.  Updates the VPS plan to set the new bandwidth limit to the amount that was previously unused.

This process is ideal for hosting providers who want to offer bandwidth carry-over as a premium feature.

---

## ✨ Features

-   **Flexible Targeting:** Reset bandwidth for a single VPS, a specific list of VPSs, or all servers on the node.
-   **Intelligent Calculation:** Automatically calculates unused bandwidth and applies it as the new limit.
-   **Plan Preservation:** Preserves the original service plan (`plid`) to avoid accidental upgrades or downgrades.
-   **Safe & Robust:** Includes health checks, error handling, and detailed logging.
-   **Idempotent:** Skips servers on unlimited plans to prevent errors.

---

## 🔧 Prerequisites

Before running this script, ensure the following command-line utilities are installed on your system:

-   `curl`: Used for making API requests.
-   `jq`: A lightweight and flexible command-line JSON processor.

You can install them on most Linux distributions using the system's package manager:

```bash
# On CentOS / RHEL / AlmaLinux
sudo yum install curl jq

# On Debian / Ubuntu
sudo apt-get install curl jq
```

---

## ⚙️ Configuration

All configuration is done by editing the variables at the top of the `reset_band.sh` script file.

```bash
############################################################
# 0. CONFIG
############################################################
<<<<<<< HEAD
HOST="1.1.1.1"
KEY="aVoOyZ75cXGgwbAQAFuGa1haJNRsXhLJ"
PASS="bhGXRTVwqDs9Zj3shVDuc6GJLRSa2lBV"
=======
HOST="85.133.221.224"
KEY="bVoOyZ75cXGgwbAQAFuGa1haJNRsXhLJ"
PASS="JhGXRTVwqDs9Zj3shVDuc6GJLRSa2lBV"
>>>>>>> a95da423b4ccee89c79547ba9600cbd5481f29b3
```

-   `HOST`: The IP address of your Virtualizor master node.
-   `KEY` / `PASS`: Your Virtualizor Admin API credentials. Ensure the API key has privileges to **List VPS**, **Edit VPS**, and **Reset Bandwidth**.

---

## 🚀 Usage

1.  **Save the Script:** Save the code as `reset_band.sh`.

2.  **Make it Executable:**
    ```bash
    chmod +x reset_band.sh
    ```

3.  **Run the Script:**

    * **To reset a single VPS:**
        ```bash
        ./reset_band.sh -m single -v <VPS_ID>
        # Example
        ./reset_band.sh -m single -v 901
        ```

    * **To reset a specific list of VPSs:**
        ```bash
        ./reset_band.sh -m single -v <ID1,ID2,ID3>
        # Example
        ./reset_band.sh -m single -v 901,905,912
        ```

    * **To reset all VPSs on the node:**
        ```bash
        ./reset_band.sh -m all
        ```

---

## 📝 Logging

The script generates two log files in the `/tmp/` directory for easy debugging and auditing:

-   `/tmp/reset_band.log`: A detailed, verbose log of all actions, including API connection status, targets, calculations, and any errors encountered.
-   `/tmp/reset_band_changes.log`: A clean, concise audit log that only contains entries for successfully processed servers, showing the "before and after" bandwidth states.

**Example `change_log` entry:**
```
2025-07-27 17:00:05T  VPS 901  3/3997 => 0/3994 (plan 2)
```

---

## 📜 License

This project is licensed under the MIT License. See the `LICENSE` file for details.
