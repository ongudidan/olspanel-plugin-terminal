# OLSPanel SSH Web Terminal Plugin

An official plugin for **OLSPanel** to provide a secure, native, interactive web-based SSH terminal directly inside the admin panel.

## Features
- **In-Browser Terminal**: Fully interactive bash/ssh shell without leaving OLSPanel.
- **Secure Internal Binding**: Binds backend WebSockets to localhost and proxies them securely.
- **Responsive Layout**: Adapts beautifully to screen sizes.
- **Micro-animations & Fast Responses**: Extremely low latency shell streaming.

## Installation

### Method 1: Direct Command Line (Recommended)
Run the following command as root on your OLSPanel server:
```bash
sudo install_cp_plugin https://github.com/ongudidan/olspanel-plugin-terminal/releases/latest/download/terminal.zip
```

### Method 2: Manual Web UI
1. Download `terminal.zip` from the latest release in this repository.
2. Log into your **OLSPanel Admin Control Panel**.
3. Go to **Plugins** -> **Install Plugin** and upload `terminal.zip`.
4. Wait for the automatic reload to complete.

## Development & Packing
To pack the plugin manually, make sure Composer dependencies are installed first:
```bash
cd terminal
composer install --no-dev --optimize-autoloader
cd ..
zip -r terminal.zip terminal/
```

## Release Automation
Simply push a version tag to trigger the automatic build and release:
```bash
git tag v1.0.0
git push origin v1.0.0
```
The GitHub Action will automatically fetch composer dependencies, package the plugin, and publish the asset.

