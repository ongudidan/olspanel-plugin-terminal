# OLSPanel SSH Web Terminal Plugin

An official plugin for **OLSPanel** to provide a secure, native, interactive web-based SSH terminal directly inside the admin panel.

## Features
- **In-Browser Terminal**: Fully interactive bash/ssh shell without leaving OLSPanel.
- **Secure Internal Binding**: Binds backend WebSockets to localhost and proxies them securely.
- **Responsive Layout**: Adapts beautifully to screen sizes.
- **Micro-animations & Fast Responses**: Extremely low latency shell streaming.

## Installation

### Method 1: Direct Command Line (Recommended)
You can install the latest release directly:
```bash
sudo install_cp_plugin https://github.com/ongudidan/olspanel-plugin-terminal/releases/latest/download/terminal.zip
```

Or target a specific version (e.g., `v1.0.0`):
```bash
sudo install_cp_plugin https://github.com/ongudidan/olspanel-plugin-terminal/releases/download/v1.0.0/terminal_v1.0.0.zip
```

### Method 2: Manual Web UI
1. Go to the **Releases** page of this repository.
2. Download either the static `terminal.zip` or the version-specific `terminal_vX.Y.Z.zip` asset.
3. Log into your **OLSPanel Admin Control Panel**.
4. Go to **Plugins** -> **Install Plugin** and upload the downloaded zip.
5. Wait for the automatic reload to complete.

## Development & Packing
To pack the plugin manually, run this from the root of the repository:
```bash
cd terminal
composer install --no-dev --optimize-autoloader
cd ..
zip -r terminal.zip terminal/ -x "*/.git*" -x "*.git*"
```

## Release Automation

### Option 1: Trigger via GitHub UI (Auto-increment)
1. Navigate to the **Actions** tab on GitHub.
2. Select the **Build and Release...** workflow.
3. Click the **Run workflow** button, select version level increment (`patch`, `minor`, `major`), and run.
4. The system will automatically compute the next version, tag it, and publish the release.

### Option 2: Manual Tag Push
If you prefer manual versioning:
```bash
git tag v1.0.0
git push origin v1.0.0
```
This triggers the Action to setup dependencies, compile, and publish that exact version.

