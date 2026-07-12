#!/bin/bash

# ===== PARAMS =====
USERNAME="$1"
PASSWORD="$2"
SUDO_NOPASSWD="${3:-yes}"

# ===== VALIDATION =====
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run as root"
  exit 1
fi

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
  echo "Usage: $0 <username> <password> [yes|no]"
  exit 1
fi

# ===== CREATE OR UPDATE USER =====
if id "$USERNAME" &>/dev/null; then
  echo "ℹ️ User $USERNAME exists — updating password"
else
  useradd -m -s /bin/bash "$USERNAME"
  echo "✅ User $USERNAME created"
fi

# ===== SET / UPDATE PASSWORD =====
echo "$USERNAME:$PASSWORD" | chpasswd
echo "🔐 Password updated for $USERNAME"

# ===== ENSURE SHELL CONFIGS =====
for file in .bashrc .profile; do
  if [ ! -f "/home/$USERNAME/$file" ] && [ -f "/etc/skel/$file" ]; then
    cp "/etc/skel/$file" "/home/$USERNAME/$file"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/$file"
    chmod 644 "/home/$USERNAME/$file"
  fi
done

# ===== SYMLINK NODEJS GLOBALLY =====
if [ -d "/usr/local/olspanel/bin/nodejs" ]; then
  NODE_VER=$(ls -1 /usr/local/olspanel/bin/nodejs/ 2>/dev/null | grep -E '^[0-9]+$' | sort -nr | head -n 1)
  if [ -n "$NODE_VER" ]; then
    NODE_BIN_DIR="/usr/local/olspanel/bin/nodejs/$NODE_VER/bin"
    if [ -f "$NODE_BIN_DIR/node" ]; then
      ln -sf "$NODE_BIN_DIR/node" /usr/local/bin/node
      ln -sf "$NODE_BIN_DIR/npm" /usr/local/bin/npm
      ln -sf "$NODE_BIN_DIR/npx" /usr/local/bin/npx
    fi
  fi
fi

# ===== SUDO ACCESS & JAIL CONFIG =====
SUDO_FILE="/etc/sudoers.d/$USERNAME"

if [ "$SUDO_NOPASSWD" = "yes" ]; then
  # Grant full passwordless sudo access (for admins)
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
  # Ensure admin is not jailed
  gpasswd -d "$USERNAME" jailed_users 2>/dev/null || true
  echo "⚡ Full sudo access (NOPASSWD) enabled"
else
  # Deny sudo access for regular users
  gpasswd -d "$USERNAME" wheel 2>/dev/null || true
  gpasswd -d "$USERNAME" sudo 2>/dev/null || true
  rm -f "$SUDO_FILE"
  echo "⚡ Sudo access denied"

  # Silence login greeting messages / host info leakage
  touch "/home/$USERNAME/.hushlogin"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/.hushlogin"
  chmod 644 "/home/$USERNAME/.hushlogin"

  # Ensure jailed_users group exists
  groupadd -f jailed_users
  usermod -aG jailed_users "$USERNAME"

  # Setup SSH Daemon config one-time setup
  SSHD_CONFIG="/etc/ssh/sshd_config"
  if [ -f "$SSHD_CONFIG" ]; then
    if ! grep -q "Match Group jailed_users" "$SSHD_CONFIG"; then
      echo -e "\n# OLSPanel Jailed Shell VirtFS config\nMatch Group jailed_users\n    ChrootDirectory /home/virtfs/%u" >> "$SSHD_CONFIG"
      if sshd -t; then
        if systemctl is-active --quiet sshd 2>/dev/null; then
          systemctl restart sshd
        elif systemctl is-active --quiet ssh 2>/dev/null; then
          systemctl restart ssh
        fi
      else
        # Revert config if test fails
        sed -i '/# OLSPanel Jailed Shell VirtFS config/,+2d' "$SSHD_CONFIG"
      fi
    fi
  fi

  # Setup VirtFS directory structure
  JAIL_ROOT="/home/virtfs/$USERNAME"
  mkdir -p "$JAIL_ROOT"
  mkdir -p "$JAIL_ROOT"/{bin,lib,lib64,usr,sbin,etc,home/"$USERNAME",dev,tmp,etc/alternatives,etc/ssl,var/spool/cron,etc/php}

  # Helper functions to bind mount read-only or read-write safely
  safe_mount_ro() {
    local src="$1"
    local dest="$2"
    if [ -d "$src" ]; then
      if ! grep -q " $dest " /proc/mounts; then
        mount --bind "$src" "$dest"
        mount -o remount,ro,bind "$dest"
      fi
    fi
  }

  safe_mount_rw() {
    local src="$1"
    local dest="$2"
    if [ -d "$src" ]; then
      if ! grep -q " $dest " /proc/mounts; then
        mount --bind "$src" "$dest"
      fi
    fi
  }

  # Bind mount system files (Read-Only)
  safe_mount_ro "/bin" "$JAIL_ROOT/bin"
  safe_mount_ro "/lib" "$JAIL_ROOT/lib"
  safe_mount_ro "/lib64" "$JAIL_ROOT/lib64"
  safe_mount_ro "/usr" "$JAIL_ROOT/usr"
  safe_mount_ro "/sbin" "$JAIL_ROOT/sbin"
  safe_mount_ro "/dev" "$JAIL_ROOT/dev"
  safe_mount_ro "/etc/alternatives" "$JAIL_ROOT/etc/alternatives"
  safe_mount_ro "/etc/ssl" "$JAIL_ROOT/etc/ssl"
  safe_mount_ro "/etc/php" "$JAIL_ROOT/etc/php"

  # Bind mount user home directory and cron directory (Read-Write)
  safe_mount_rw "/home/$USERNAME" "$JAIL_ROOT/home/$USERNAME"
  safe_mount_rw "/var/spool/cron" "$JAIL_ROOT/var/spool/cron"

  # Mount tmpfs writeable space for /tmp inside the jail
  if ! grep -q " $JAIL_ROOT/tmp " /proc/mounts; then
    mount -t tmpfs none "$JAIL_ROOT/tmp"
  fi

  # Build minimal jailed /etc files to keep environment independent
  UID_VAL=$(id -u "$USERNAME")
  GID_VAL=$(id -g "$USERNAME")
  echo "root:x:0:0:root:/root:/bin/bash" > "$JAIL_ROOT/etc/passwd"
  echo "$USERNAME:x:$UID_VAL:$GID_VAL::/home/$USERNAME:/bin/bash" >> "$JAIL_ROOT/etc/passwd"
  echo "root:x:0:" > "$JAIL_ROOT/etc/group"
  echo "$USERNAME:x:$GID_VAL:" >> "$JAIL_ROOT/etc/group"

  cp -f /etc/resolv.conf "$JAIL_ROOT/etc/resolv.conf" 2>/dev/null || true
  cp -f /etc/hosts "$JAIL_ROOT/etc/hosts" 2>/dev/null || true
fi

# ===== DONE =====
echo "================================="
echo "User      : $USERNAME"
echo "SSH Login : Password-based"
echo "Sudo      : $SUDO_NOPASSWD"
echo "================================="
