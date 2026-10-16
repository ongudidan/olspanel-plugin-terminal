import requests
import os
import stat
import json
import subprocess
import binascii
import random
import string
import zipfile
import shutil
import time
import socket
from django.views.decorators.csrf import csrf_exempt
from django.utils.decorators import method_decorator
from django.http import JsonResponse,Http404
from django.shortcuts import render, redirect, get_object_or_404
from django.urls import reverse_lazy,reverse
from django.contrib.auth.views import LoginView
from django.contrib import messages
from django.contrib.messages.views import SuccessMessageMixin
from django.views import View
from django.contrib.auth.decorators import login_required
from django.http import HttpResponse
from users.models import * 
from users.server_core import *  # Import your function
from users.database import *  # Import your function
from django.db import connection
from users.function import *  # Import your function
from users.bandwidth import *  # Import your function
from django.contrib.auth.hashers import make_password
from ftplib import FTP, error_perm
from file_manager.function_file import *
from ftplib import FTP
from urllib.parse import urlparse
from django.contrib.auth import update_session_auth_hash, authenticate, logout, login
from django.conf import settings
from users.decorators import * 
from whm.decorators import * 
from django.views.decorators.clickjacking import xframe_options_exempt
from users.plugin import * 
from whm.models import *
from file_manager.models import * 
from django.conf import settings
from whm.function import * 

def get_php_binary():
    """
    Finds a valid PHP CLI binary with the ssh2 extension loaded.
    Searches system PATH, standard binary locations, and versioned paths.
    """
    candidates = []

    # 1. System default php binary in PATH
    which_php = shutil.which('php')
    if which_php:
        candidates.append(which_php)

    # 2. Common standard CLI paths
    common_paths = [
        '/usr/bin/php',
        '/usr/local/bin/php',
        '/bin/php',
        '/usr/bin/php8.5',
        '/usr/bin/php8.4',
        '/usr/bin/php8.3',
        '/usr/bin/php8.2',
        '/usr/bin/php8.1',
        '/usr/bin/php8.0',
        '/usr/bin/php7.4',
    ]
    for p in common_paths:
        if p not in candidates:
            candidates.append(p)

    # 3. Check AppSettings cgi_bin if configured
    try:
        from users.models import AppSettings
        cgi_val = AppSettings.objects.get(setting_key='cgi_bin').setting_value.strip()
        replaced = cgi_val.replace('php-cgi', 'php')
        if replaced not in candidates:
            candidates.append(replaced)
    except Exception:
        pass

    # Priority 1: Pick an executable candidate that has the ssh2 extension loaded
    for cand in candidates:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            try:
                res = subprocess.run([cand, '-m'], capture_output=True, text=True, timeout=2)
                if 'ssh2' in res.stdout.lower():
                    return cand
            except Exception:
                pass

    # Priority 2: Fall back to any executable candidate
    for cand in candidates:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand

    return 'php'


@loginadminoruser
def index(request):
    # ===== GET PARAMS =====
    token = generate_text(32)
    password = generate_text()
    t_port = get_current_ssh_port() or 22

    # Determine if admin is impersonating a user (request.user != request.admin_user)
    is_impersonating = False
    if hasattr(request, 'admin_user') and request.admin_user:
        if request.user and request.user.is_authenticated and request.user != request.admin_user:
            is_impersonating = True

    if hasattr(request, 'admin_user') and request.admin_user and not is_impersonating:
        username = "olsadmin"
        sudo_access = "yes"
    else:
        username = request.user.username
        sudo_access = "no"

    if not token or not username or not password:
        return JsonResponse({
            "status": "error",
            "message": "token, username, password required"
        }, status=400)

    # ===== LOAD PHP BINARY =====
    
    script_path = os.path.join(settings.BASE_DIR, 'modules', 'webterminal', 'add_user.sh')        
    subprocess.run(f"sed -i 's/\\r$//' {script_path}", shell=True, check=True)        
    subprocess.run(f"chmod +x {script_path}", shell=True)
    cmd = [
        "bash", script_path,
        username, password,
        sudo_access
    ]
    subprocess.run(cmd, capture_output=True, text=True)

    # ===== SAVE SESSION TO JSON FILE =====
    sessions_file = '/tmp/webterminal_sessions.json'
    sessions = {}
    if os.path.exists(sessions_file):
        try:
            with open(sessions_file, 'r') as f:
                sessions = json.load(f)
                if not isinstance(sessions, dict):
                    sessions = {}
        except Exception:
            pass

    sessions[token] = {
        "username": username,
        "password": password,
        "port": t_port,
        "created_at": time.time()
    }

    # Clean old sessions (older than 2 minutes)
    now = time.time()
    sessions = {t: s for t, s in sessions.items() if now - s["created_at"] < 120}

    try:
        with open(sessions_file, 'w') as f:
            json.dump(sessions, f)
        os.chmod(sessions_file, 0o660)
    except Exception:
        pass

    # ===== SERVER FILE =====
    PROJECT_ROOT = settings.BASE_DIR
    server_file = os.path.join(
        PROJECT_ROOT, "3rdparty/webterminal/server.php"
    )

    # ===== CHECK IF PORT 9090 IS RUNNING =====
    server_running = False
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(('127.0.0.1', 9090))
            server_running = True
    except socket.error:
        pass

    pid = None
    status = "ok"
    if not server_running:
        # First attempt: Try systemctl if webterminal service exists
        try:
            res = subprocess.run(['systemctl', 'restart', 'webterminal'], capture_output=True, timeout=3)
            if res.returncode == 0:
                for _ in range(20):
                    try:
                        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                            s.settimeout(0.1)
                            s.connect(('127.0.0.1', 9090))
                            server_running = True
                            break
                    except socket.error:
                        time.sleep(0.1)
        except Exception:
            pass

        # Second attempt: Spawn standalone server.php process if still not listening
        if not server_running:
            try:
                PHP_BINARY = get_php_binary()
                log_file = open('/tmp/webterminal.log', 'a')
                log_file.write(f"\n[{time.ctime()}] Starting webterminal daemon with binary: {PHP_BINARY}\n")
                log_file.flush()

                process = subprocess.Popen(
                    [PHP_BINARY, server_file],
                    stdout=log_file,
                    stderr=log_file,
                    start_new_session=True  # detach from Django
                )
                pid = process.pid
                
                # Wait for server to start listening (up to 3 seconds)
                for _ in range(30):
                    try:
                        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                            s.settimeout(0.1)
                            s.connect(('127.0.0.1', 9090))
                            server_running = True
                            break
                    except socket.error:
                        time.sleep(0.1)

                if not server_running:
                    status = "error"
                    with open('/tmp/webterminal.log', 'a') as f:
                        f.write(f"[{time.ctime()}] ERROR: server.php failed to bind to 127.0.0.1:9090 within timeout.\n")
            except Exception as e:
                status = "error"
                try:
                    with open('/tmp/webterminal.log', 'a') as f:
                        f.write(f"[{time.ctime()}] Exception launching server.php: {e}\n")
                except Exception:
                    pass

    return JsonResponse({
        "status": status,
        "pid": pid,
        "token": token
    })


@loginadminoruser
def gui(request):
    is_impersonating = False
    if hasattr(request, 'admin_user') and request.admin_user:
        if request.user and request.user.is_authenticated and request.user != request.admin_user:
            is_impersonating = True

    if hasattr(request, 'admin_user') and request.admin_user and not is_impersonating:
        base_template = 'whm/base.html'
    else:
        base_template = 'users/base.html'

    return render(request, 'webterminal/gui.html', {
        'base_template': base_template,
    })



def generate_text(length=16):
    """Generate a strong random password using only A-Z and a-z characters."""
    if length < 12:  # Enforce a minimum length for security
        length = 12

    # Create a pool of characters (A-Z and a-z)
    all_characters = string.ascii_letters  # This includes both uppercase and lowercase letters

    # Generate a random password by selecting random characters from the pool
    password = random.choices(all_characters, k=length)

    return ''.join(password)            