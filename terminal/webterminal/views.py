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


@loginadminoruser
def index(request):
    # ===== GET PARAMS =====
    token = generate_text(32)
    password = generate_text()
    t_port = get_current_ssh_port()

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

    try:
        PHP_BINARY = AppSettings.objects.get(
            setting_key='cgi_bin'
        ).setting_value.strip()
        if 'php-cgi' in PHP_BINARY:
            PHP_BINARY = PHP_BINARY.replace('php-cgi', 'php')
    except AppSettings.DoesNotExist:
        PHP_BINARY = '/usr/bin/php8.2'

    # ===== SERVER FILE =====
    PROJECT_ROOT = settings.BASE_DIR
    server_file = os.path.join(
        PROJECT_ROOT, "3rdparty/webterminal/server.php"
    )

    subprocess.run(
        "kill -9 $(lsof -t -i:9090)",
        shell=True,
        check=False)

    env = os.environ.copy()
    env.update({
        "TERMINAL_TOKEN": str(token),
        "TERMINAL_USER": str(username),
        "TERMINAL_PASS": str(password),
        "TERMINAL_PORT": str(t_port),   # ✅ FIX
        })


    # ===== START PROCESS =====
    try:
        process = subprocess.Popen(
            [PHP_BINARY, server_file],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True  # detach from Django
        )
        pid = process.pid
        status = "ok"
    except Exception as e:
        pid = None
        status = "error"

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