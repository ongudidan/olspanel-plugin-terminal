#!/bin/bash

# Detect OLSPanel directory
BASE_DIR="/usr/local/olspanel/mypanel"
if [ ! -d "$BASE_DIR" ]; then
  # Fallback to local discovery
  BASE_DIR="$(pwd)"
  if [ ! -f "$BASE_DIR/manage.py" ]; then
    BASE_DIR="$(dirname "$(dirname "$BASE_DIR")")"
  fi
fi

# Detect active PHP version and install php-ssh2 extension if missing
if ! php -m | grep -qi ssh2 2>/dev/null; then
  echo "Installing PHP SSH2 extension..."
  PHP_VER=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
  if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/almalinux-release ]; then
    PM_BIN="dnf"
    if ! command -v dnf &> /dev/null; then
      PM_BIN="yum"
    fi
    if [ -n "$PHP_VER" ]; then
      PHP_VER_NO_DOT=$(echo "$PHP_VER" | tr -d '.')
      sudo $PM_BIN install -y "lsphp${PHP_VER_NO_DOT}-pecl-ssh2" || sudo $PM_BIN install -y php-ssh2
    else
      sudo $PM_BIN install -y php-ssh2
    fi
  else
    if [ -n "$PHP_VER" ]; then
      apt-get update -y
      apt-get install -y "php${PHP_VER}-ssh2" || apt-get install -y php-ssh2
    else
      apt-get update -y && apt-get install -y php-ssh2
    fi
  fi
fi

# Configure SSHD to allow password authentication for loopback connections (safe & required for PHP terminal wrapper)
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
  if ! grep -q "Match Address 127.0.0.1,::1" "$SSHD_CONFIG"; then
    echo -e "\nMatch Address 127.0.0.1,::1\n    PasswordAuthentication yes" >> "$SSHD_CONFIG"
    if sshd -t; then
      if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd
      elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh
      fi
      echo "✅ SSHD loopback password authentication configured successfully"
    else
      # Revert changes if configuration test fails
      sed -i '/Match Address 127.0.0.1,::1/,+1d' "$SSHD_CONFIG"
      echo "❌ Error: sshd config test failed after adding loopback match, reverted changes"
    fi
  else
    echo "ℹ️ SSHD loopback password authentication already configured"
  fi
fi

# Deploy the Django webterminal module from the bundled source folder
MODULE_SRC="$BASE_DIR/3rdparty/webterminal/webterminal"
MODULE_DEST="$BASE_DIR/modules/webterminal"

if [ -d "$MODULE_SRC" ]; then
  # Clean up existing module directory to prevent stale/duplicate file configurations
  rm -rf "$MODULE_DEST"
  mkdir -p "$BASE_DIR/modules"
  cp -r "$MODULE_SRC" "$BASE_DIR/modules/"
  chown -R www-data:www-data "$MODULE_DEST"
  echo "✅ Django webterminal module deployed to $MODULE_DEST"
else
  echo "❌ Error: Django webterminal module source not found at $MODULE_SRC"
  exit 1
fi

USER_BASE_HTML="$BASE_DIR/users/templates/users/base.html"
WHM_BASE_HTML="$BASE_DIR/whm/templates/whm/base.html"
USER_FOOTER_HTML="$BASE_DIR/users/templates/users/footer.html"
WHM_FOOTER_HTML="$BASE_DIR/whm/templates/whm/footer.html"
USER_DB_IMPORT_HTML="$BASE_DIR/users/templates/users/db_import.html"


# Patch 3b: Fix AttributeError NoneType object has no attribute get in users/views.py for superuser user_data
VIEWS_FILE="$BASE_DIR/users/views.py"
if [ -f "$VIEWS_FILE" ]; then
  python3 -c "
import os
file_path = '$VIEWS_FILE'
with open(file_path, 'r') as f:
    content = f.read()

target = '''            if request.user:
                user_data = get_user_data_by_id(request.user.id)
                whm = user_data.get('whm', 0)
            elif request.admin_user:
                user_data = get_user_data_by_id(request.admin_user.id)
                whm = user_data.get('whm', 0)'''

replacement = '''            if request.user:
                user_data = get_user_data_by_id(request.user.id)
                whm = user_data.get('whm', 0) if user_data else (1 if request.user.is_superuser or request.user.is_staff else 0)
            elif request.admin_user:
                user_data = get_user_data_by_id(request.admin_user.id)
                whm = user_data.get('whm', 0) if user_data else (1 if request.admin_user.is_superuser or request.admin_user.is_staff else 0)'''

if target in content:
    with open(file_path, 'w') as f:
        f.write(content.replace(target, replacement))
    import py_compile
    py_compile.compile(file_path)
    print('views.py patched successfully')
"
fi

# Patch 5: Replace external jQuery CDNs with local files to prevent slow browser tab loading
python3 -c "
import os

files = ['$USER_FOOTER_HTML', '$WHM_FOOTER_HTML', '$USER_DB_IMPORT_HTML']
for file_path in files:
    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()
        
        if 'https://code.jquery.com' in content:
            content = content.replace('https://code.jquery.com/jquery-3.5.1.slim.min.js', '/media/js/jquery.min.js')
            content = content.replace('https://code.jquery.com/jquery-3.6.0.min.js', '/media/js/jquery.min.js')
            with open(file_path, 'w') as f:
                f.write(content)
            print('Patched jQuery CDN link in: ' + file_path)
"

# Deploy SVG vector icon for color adaptation support
ICON_SRC="$BASE_DIR/3rdparty/webterminal/plugin_icon.svg"
ICON_DEST="$BASE_DIR/media/icon/webterminal.svg"

if [ -f "$ICON_SRC" ]; then
  cp -f "$ICON_SRC" "$ICON_DEST"
  chown www-data:www-data "$ICON_DEST"
  echo "✅ SVG vector icon deployed to $ICON_DEST"
else
  echo "❌ Error: SVG icon source not found: $ICON_SRC"
  exit 1
fi

# Asynchronously restart the OLSPanel service to load changes
if systemctl is-active --quiet cp 2>/dev/null; then
  (sleep 2 && systemctl restart cp) &
fi
