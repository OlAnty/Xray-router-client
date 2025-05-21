
# Xray VLESS Router Client (Entware/OpenWRT)

A one-stop shell script toolkit to install, configure, and manage a VLESS proxy client on routers running Entware (like OpenWRT).

The configuration can proxy:
  - **All traffic** from the router to your VPN server
  - **Traffic to specific domains** like `youtube.com`, `netflix.com`, etc.
  - **Traffic from specific devices** on your LAN (e.g., Smart TVs, consoles) by IP

## Requirements

- Router running **Entware** (e.g., OpenWRT)
- A working **VPN server** supporting VLESS + Reality
- A valid **VLESS configuration** (server IP,UUID, PubKey, short ID, serverName)

## Usage
Choose a folder to download and unpack the scripts.
```sh
cd /tmp
```
Download and unpack.
```sh
wget https://github.com/OlAnty/Xray-router-client/archive/refs/heads/main.zip -O xray.zip
unzip xray.zip
cd Xray-router-client-main
```
Start the Xray admin.
```sh
sudo sh xray-proxy-admin.sh
```
On first run, this will offer to install itself as `xray-proxy-admin` globally.
Follow the menu to install the proxy client.

If it fails to install itself as `xray-proxy-admin` globally, run `install_all.sh`

```sh
sudo sh install_all.sh
```

### Install xray proxy

Use option `1) Installation` from the menu to:
- Install required packages
- Prompt you to configure your VPN
- Generate all config and helper scripts
- Set up firewall redirect rules
- Start the proxy and watchdog
- Test the setup automatically

The script will auto-generate:
  - VLESS config
  - iptables routing script
  - watchdog and log management script
  - init.d client launcher

## Connectivity test

The test is automatically run post-install and can be manually run any time.

- Ensures DNS, HTTPS, and VPN routing are working
- Automatically avoids redirecting traffic from the same UID to prevent infinite loops
- Shows routing confirmation from logs

## Iptables behavior

The proxy works by creating a custom `XRAY_REDIRECT` chain and adding:

- PREROUTING rules for selected IPs or all LAN traffic
- OUTPUT rules for UID-based redirection

If your router is actively used for SSH or other services, you need to manually exclude the Xray UID from iptables redirection to avoid routing loops.
Add this rule after starting Xray:

```sh
XRAY_UID=$(ps -o uid= -p "$(pgrep -f '/opt/sbin/xray')" | tr -d ' ')
iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$XRAY_UID" -j XRAY_REDIRECT
```

## Uninstallation

Use menu option `1) Installation → 2) Uninstall Xray` to:

- Stop all proxy and watchdog processes
- Remove iptables rules
- Delete init.d scripts and config files

## Included Files

| Script Name             | Purpose                                |
|------------------------|----------------------------------------|
| xray-proxy-admin.sh     | Main admin interface                   |
| install_all.sh          | Orchestrates full setup                |
| dependencies.sh         | Installs needed packages               |
| vless_config.sh         | Builds VLESS config                    |
| routes_script.sh        | Adds PREROUTING firewall rules         |
| client_launcher.sh      | Creates init.d Xray launcher           |
| log_monitoring.sh       | Adds log + watchdog                    |
| connectivity_test.sh    | Tests actual proxy traffic             |

## Disclaimer

> This tool modifies system-level iptables and adds startup scripts.
> Ensure you fully understand its effects before deploying on production routers.

Test on a secondary device or virtual instance if unsure.
The scripts are fully compatible and tested on Debian 11.
