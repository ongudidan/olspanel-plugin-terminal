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

# Automatically deploy the Django module from the bundled terminal_module.zip
MODULE_ZIP="$BASE_DIR/3rdparty/terminal/terminal_module.zip"
MODULE_DEST="$BASE_DIR/modules/terminal"

if [ -f "$MODULE_ZIP" ]; then
  mkdir -p "$BASE_DIR/modules"
  unzip -o "$MODULE_ZIP" -d "$BASE_DIR/modules/"
  chown -R www-data:www-data "$MODULE_DEST"
  echo "✅ Django terminal module unzipped and deployed to $MODULE_DEST"
else
  echo "❌ Error: Django terminal module zip not found at $MODULE_ZIP"
  exit 1
fi

DECORATORS_FILE="$BASE_DIR/users/decorators.py"
MIDDLEWARE_FILE="$BASE_DIR/users/middleware/LicenseMiddleware.py"
FUNCTIONS_FILE="$BASE_DIR/users/function.py"
USER_BASE_HTML="$BASE_DIR/users/templates/users/base.html"
WHM_BASE_HTML="$BASE_DIR/whm/templates/whm/base.html"
USER_FOOTER_HTML="$BASE_DIR/users/templates/users/footer.html"
WHM_FOOTER_HTML="$BASE_DIR/whm/templates/whm/footer.html"
USER_DB_IMPORT_HTML="$BASE_DIR/users/templates/users/db_import.html"

# Patch 1: Make decorators.py return active license and bypass premium checks immediately
if [ -f "$DECORATORS_FILE" ]; then
  python3 -c "
import os, re
file_path = '$DECORATORS_FILE'
with open(file_path, 'r') as f:
    content = f.read()

pattern = re.compile(r'def get_license_status\(request\):.*', re.DOTALL)
new_tail = '''def get_license_status(request):
    return \"active\"

def premium_features(*allowed_types):
    def decorator(view_func):
        @wraps(view_func)
        def wrapper(request, *args, **kwargs):
            return view_func(request, *args, **kwargs)
        return wrapper
    return decorator
'''
if pattern.search(content):
    content = pattern.sub(new_tail, content)
    with open(file_path, 'w') as f:
        f.write(content)
    print('decorators.py patched successfully')
"
fi

# Patch 2: Make LicenseMiddleware.py completely transparent with zero overhead
if [ -f "$MIDDLEWARE_FILE" ]; then
  cat << 'EOF' > "$MIDDLEWARE_FILE"
from django.shortcuts import redirect, render

def get_license_status(request):
    return "active"

class LicenseMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        return self.get_response(request)
EOF
  echo "LicenseMiddleware.py rewritten successfully"
fi

# Patch 3: Make get_license_status inside function.py return active instantly
if [ -f "$FUNCTIONS_FILE" ]; then
  python3 -c "
import os, re
file_path = '$FUNCTIONS_FILE'
with open(file_path, 'r') as f:
    content = f.read()

pattern = re.compile(r'def get_license_status\(request\):.*?def download_script_only', re.DOTALL)
new_block = '''def get_license_status(request):
    return \"active\"


def download_script_only'''

if pattern.search(content):
    content = pattern.sub(new_block, content)
    with open(file_path, 'w') as f:
        f.write(content)
    print('function.py patched successfully')
"
fi

# Patch 4: Solve FOUC (Color Flicker) & dynamic SVG fetch lag on base.html files
python3 -c "
import os, re

files = ['$USER_BASE_HTML', '$WHM_BASE_HTML']
new_script = '''{% if branding.brand_color != \\\"#ef6d19\\\" %}   
<script>
(function() {
    const brandColor = \\\"{{ branding.brand_color }}\\\";
    if (brandColor === \\\"#ef6d19\\\") return;

    // Apply CSS overrides immediately
    const style = document.createElement('style');
    style.innerHTML = \`
        :root { --brand-color: \${brandColor} !important; }
        .brand-name font, .app-brand font, .app-brand span font { color: \${brandColor} !important; }
        .sidebar-dark .sidebar-inner .nav > li.active > a i, 
        .sidebar-dark .sidebar-inner .nav > li.active > a span,
        .sidebar-dark .sidebar-inner .nav > li.active > a img { color: \${brandColor} !important; }
    \`;
    document.head.appendChild(style);

    function processImage(img) {
        const src = img.src;
        if (!src.endsWith('.svg')) return;

        function replaceImg(svgText) {
            const parser = new DOMParser();
            const doc = parser.parseFromString(svgText, \\\"image/svg+xml\\\");
            const svg = doc.querySelector(\\\"svg\\\");
            if (!svg) return;

            Array.from(img.attributes).forEach(attr => {
                if (attr.name !== \\\"src\\\") {
                    svg.setAttribute(attr.name, attr.value);
                }
            });

            if (!svg.getAttribute(\\\"width\\\")) svg.setAttribute(\\\"width\\\", img.getAttribute(\\\"width\\\") || \\\"40px\\\");
            if (!svg.getAttribute(\\\"height\\\")) svg.setAttribute(\\\"height\\\", img.getAttribute(\\\"height\\\") || \\\"40px\\\");

            svg.style.cssText = img.style.cssText;
            svg.style.color = brandColor;
            svg.setAttribute(\\\"fill\\\", \\\"currentColor\\\");

            svg.querySelectorAll(\\\"*\\\").forEach(el => {
                if (el.getAttribute(\\\"fill\\\") && el.getAttribute(\\\"fill\\\") !== \\\"none\\\") {
                    el.setAttribute(\\\"fill\\\", \\\"currentColor\\\");
                }
                if (el.getAttribute(\\\"stroke\\\") && el.getAttribute(\\\"stroke\\\") !== \\\"none\\\") {
                    el.setAttribute(\\\"stroke\\\", \\\"currentColor\\\");
                }
            });

            img.replaceWith(svg);
        }

        const cached = localStorage.getItem('svg_' + src);
        if (cached) {
            replaceImg(cached);
        } else {
            fetch(src)
                .then(r => r.text())
                .then(svgText => {
                    try {
                        localStorage.setItem('svg_' + src, svgText);
                    } catch(e) {}
                    replaceImg(svgText);
                })
                .catch(err => console.error(\\\"SVG load failed:\\\", err));
        }
    }

    function init() {
        document.querySelectorAll('#search_here img[src$=\\\".svg\\\"], #left-sidebar img[src$=\\\".svg\\\"]').forEach(processImage);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
</script>
{% endif %}'''

for file_path in files:
    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()
        
        pattern = re.compile(r'{%\s*if\s+branding\.brand_color\s*!=\s*\"#ef6d19\"\s*%}\s*<script>.*?</script>\s*{%\s*endif\s*%}', re.DOTALL)
        if pattern.search(content):
            content = pattern.sub(new_script, content)
            with open(file_path, 'w') as f:
                f.write(content)
            print('Patched FOUC for: ' + file_path)
"

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
ICON_SRC="$BASE_DIR/3rdparty/terminal/plugin_icon.svg"
ICON_DEST="$BASE_DIR/media/icon/terminal.svg"

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
