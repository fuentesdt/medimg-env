#!/usr/bin/env bash
# install.sh — PHI-Safe Medical Imaging Environment on Ubuntu 24.04
#
# Usage:
#   sudo bash install.sh [--cuda] [--remove-ubuntu-user]
#
# Options:
#   --cuda               Force CUDA 12.1 PyTorch (auto-detected if NVIDIA GPU present)
#   --remove-ubuntu-user Remove the default 'ubuntu' user (mirrors Dockerfile behavior)
#
# Run from the directory containing claude-settings.json and motd.

set -euo pipefail

# ============================================================
# Section 0: Preflight checks
# ============================================================
FORCE_CUDA=0
REMOVE_UBUNTU_USER=0

for arg in "$@"; do
  case "$arg" in
    --cuda)               FORCE_CUDA=1 ;;
    --remove-ubuntu-user) REMOVE_UBUNTU_USER=1 ;;
    --help)
      echo "Usage: sudo bash $0 [--cuda] [--remove-ubuntu-user]"
      exit 0
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root: sudo bash $0" >&2
  exit 1
fi

# Ubuntu 24.04 check
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
    echo "ERROR: This script targets Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
  fi
else
  echo "ERROR: Cannot determine OS version (/etc/os-release not found)" >&2
  exit 1
fi

# Must be run from the repo directory so relative files are accessible
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required_file in claude-settings.json motd; do
  if [[ ! -f "$SCRIPT_DIR/$required_file" ]]; then
    echo "ERROR: Required file not found: $SCRIPT_DIR/$required_file" >&2
    echo "       Run this script from the medimg-env repository directory." >&2
    exit 1
  fi
done

# Warn if the current shell user is 'ubuntu' (risk of self-lockout if --remove-ubuntu-user is passed)
CALLER="${SUDO_USER:-$(logname 2>/dev/null || echo unknown)}"
if [[ "$CALLER" == "ubuntu" && $REMOVE_UBUNTU_USER -eq 1 ]]; then
  echo "WARNING: You are logged in as 'ubuntu' and passed --remove-ubuntu-user."
  echo "         Removing the 'ubuntu' user while logged in as ubuntu may lock you out."
  echo "         Sleeping 10 seconds — Ctrl-C to abort."
  sleep 10
fi

# GPU detection
HAVE_GPU=0
if command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null 2>&1; then
  HAVE_GPU=1
  echo "INFO: NVIDIA GPU detected."
fi
if [[ $FORCE_CUDA -eq 1 ]]; then
  HAVE_GPU=1
  echo "INFO: --cuda flag: forcing CUDA 12.1 PyTorch."
fi

VENV_DIR=/opt/medimg-env/venv

echo ""
echo "====================================================="
echo "  medimg-env host installation starting"
echo "  GPU:  $([ $HAVE_GPU -eq 1 ] && echo 'CUDA 12.1' || echo 'CPU-only')"
echo "  Venv: $VENV_DIR"
echo "====================================================="
echo ""

# ============================================================
# Section 1: System packages (APT)
# ============================================================
echo ">>> [1/20] Installing system packages..."

export DEBIAN_FRONTEND=noninteractive
export TZ=America/Chicago

apt-get update
apt-get install -y --no-install-recommends \
    build-essential cmake git curl wget unzip ca-certificates \
    python3 python3-pip python3-dev python3-venv python-is-python3 \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev libgomp1 \
    libdcmtk-dev libinsighttoolkit5-dev libhdf5-dev libgdal-dev \
    zlib1g-dev liblzma-dev libbz2-dev \
    htop tree vim \
    auditd \
    dnsutils \
    iptables iptables-persistent netfilter-persistent
apt-get clean
rm -rf /var/lib/apt/lists/*

# ============================================================
# Section 2: Node.js 22 LTS
# ============================================================
echo ">>> [2/20] Installing Node.js 22 LTS..."

if ! node --version 2>/dev/null | grep -q '^v22\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  apt-get clean
  rm -rf /var/lib/apt/lists/*
else
  echo "INFO: Node.js 22 already installed ($(node --version)), skipping."
fi

node --version
npm --version

# ============================================================
# Section 3: Python virtual environment
# ============================================================
echo ">>> [3/20] Creating Python virtual environment at $VENV_DIR..."

mkdir -p /opt/medimg-env
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel

# ============================================================
# Section 4: Scientific Python core
# ============================================================
echo ">>> [4/20] Installing scientific Python core..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    numpy scipy pandas matplotlib seaborn \
    scikit-learn scikit-image statsmodels \
    h5py tqdm joblib ipython jupyterlab ipywidgets

# ============================================================
# Section 5: Medical imaging — NIfTI, DICOM, ITK
# ============================================================
echo ">>> [5/20] Installing medical imaging libraries..."
echo "NOTE: antspyx compiles from C++ source — this may take 30-60 minutes and requires 4+ GB RAM."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    nibabel nilearn pydicom SimpleITK itk \
    antspyx dicom2nifti pynetdicom

# ============================================================
# Section 6: Vessel segmentation & image processing
# ============================================================
echo ">>> [6/20] Installing vessel segmentation / image processing libraries..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    opencv-python-headless Pillow \
    connected-components-3d edt fill-voids kimimaro \
    morphsnakes pymeshlab

# ============================================================
# Section 7: Deep learning — PyTorch (CPU or CUDA)
# ============================================================
echo ">>> [7/20] Installing PyTorch..."

if [[ $HAVE_GPU -eq 1 ]]; then
  echo "INFO: Installing CUDA 12.1 PyTorch."
  "$VENV_DIR/bin/pip" install --no-cache-dir \
      torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu121
  if ! ldconfig -p | grep -q libcuda; then
    echo "WARNING: CUDA libraries (libcuda) not found on this host."
    echo "         Install the NVIDIA CUDA toolkit before importing torch."
  fi
else
  echo "INFO: Installing CPU-only PyTorch."
  "$VENV_DIR/bin/pip" install --no-cache-dir \
      torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cpu
fi

# ============================================================
# Section 8: Medical segmentation frameworks
# ============================================================
echo ">>> [8/20] Installing medical segmentation frameworks..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    monai segmentation-models-pytorch timm einops torchio

# ============================================================
# Section 9: ML / experiment tracking
# ============================================================
echo ">>> [9/20] Installing ML / experiment tracking tools..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    mlflow wandb optuna shap imbalanced-learn xgboost lightgbm

# ============================================================
# Section 10: Data versioning & reproducibility
# ============================================================
echo ">>> [10/20] Installing data versioning tools..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    dvc hydra-core omegaconf

# ============================================================
# Section 11: Topological / graph tools
# ============================================================
echo ">>> [11/20] Installing topological / graph tools..."

"$VENV_DIR/bin/pip" install --no-cache-dir \
    gudhi ripser persim networkx vtk

# ============================================================
# Section 12: Claude Code CLI
# ============================================================
echo ">>> [12/20] Installing Claude Code CLI..."

npm install -g @anthropic-ai/claude-code
claude --version

# ============================================================
# Section 13: User and directory setup
# ============================================================
echo ">>> [13/20] Configuring users and directories..."

# Check for uid 1000 conflict
EXISTING_UID1000=$(getent passwd 1000 | cut -d: -f1 || true)
if [[ -n "$EXISTING_UID1000" && "$EXISTING_UID1000" != "developer" && "$EXISTING_UID1000" != "ubuntu" ]]; then
  echo "ERROR: uid 1000 is already assigned to '$EXISTING_UID1000'." >&2
  echo "       Manually resolve the uid conflict before running this script." >&2
  exit 1
fi

# Remove ubuntu user only if explicitly requested
if [[ $REMOVE_UBUNTU_USER -eq 1 ]]; then
  if id ubuntu &>/dev/null; then
    echo "INFO: Removing default 'ubuntu' user..."
    userdel -r ubuntu 2>/dev/null || true
  fi
else
  echo "INFO: Skipping 'ubuntu' user removal (pass --remove-ubuntu-user to remove)."
fi

# Create 'developer' user if not present
if ! id developer &>/dev/null; then
  useradd -m -u 1000 -s /bin/bash developer
  echo "INFO: Created user 'developer' (uid 1000)."
else
  echo "INFO: User 'developer' already exists."
fi

# Workspace and outputs directories
mkdir -p /workspace /outputs
chown -R developer:developer /workspace /outputs /home/developer

# ============================================================
# Section 14: Claude Code security policy
# ============================================================
echo ">>> [14/20] Installing Claude Code security policy..."

mkdir -p /home/developer/.claude
cp "$SCRIPT_DIR/claude-settings.json" /home/developer/.claude/settings.json
chown root:developer /home/developer/.claude/settings.json
chmod 444 /home/developer/.claude/settings.json   # read-only: developer can read, not write
chown developer:developer /home/developer/.claude

# ============================================================
# Section 15: Audit log
# ============================================================
echo ">>> [15/20] Creating audit log..."

touch /var/log/claude-audit.log
chown root:developer /var/log/claude-audit.log
chmod 664 /var/log/claude-audit.log

# ============================================================
# Section 16: Login banner (MOTD)
# ============================================================
echo ">>> [16/20] Installing login banner..."

cp "$SCRIPT_DIR/motd" /etc/motd
# Update wording: "container" → "environment" (accurate for host install)
sed -i 's/container/environment/g' /etc/motd
# Disable Ubuntu's dynamic MOTD scripts so our PHI banner isn't buried
chmod -x /etc/update-motd.d/* 2>/dev/null || true

# ============================================================
# Section 17: Environment variables
# ============================================================
echo ">>> [17/20] Setting environment variables..."

# System-wide non-secret values in /etc/environment
for entry in \
    "TZ=America/Chicago" \
    "DISABLE_AUTOUPDATER=1" \
    "CLAUDE_CODE_ROOTDIR=/workspace"; do
  grep -qxF "$entry" /etc/environment || echo "$entry" >> /etc/environment
done

# Developer user shell configuration
BASHRC_BLOCK='
# --- medimg-env ---
source /opt/medimg-env/venv/bin/activate
export CLAUDE_CODE_ROOTDIR=/workspace
export DISABLE_AUTOUPDATER=1
# Set your Anthropic API key (do not commit this file):
# export ANTHROPIC_API_KEY="sk-ant-..."
'
if ! grep -q '# --- medimg-env ---' /home/developer/.bashrc 2>/dev/null; then
  printf '%s\n' "$BASHRC_BLOCK" >> /home/developer/.bashrc
fi
chown developer:developer /home/developer/.bashrc

# ============================================================
# Section 18: Network egress restrictions (iptables)
# ============================================================
echo ">>> [18/20] Configuring network egress restrictions..."

DEVELOPER_UID=$(id -u developer)
ANTHROPIC_IPS=$(dig +short api.anthropic.com | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

if [[ -z "$ANTHROPIC_IPS" ]]; then
  echo "WARNING: Could not resolve api.anthropic.com IP addresses."
  echo "         Skipping iptables setup — run manually after DNS is available."
  echo "         Re-run: bash $SCRIPT_DIR/install.sh (will skip already-completed steps)"
else
  echo "INFO: Resolved api.anthropic.com → $ANTHROPIC_IPS"

  # Flush existing OUTPUT chain rules (idempotent re-runs)
  iptables -F OUTPUT 2>/dev/null || true

  # Allow established / related return traffic first
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Allow root (uid 0) unrestricted — needed for apt, systemd, etc.
  iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT

  # Allow developer: DNS (both UDP and TCP)
  iptables -A OUTPUT -m owner --uid-owner "$DEVELOPER_UID" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -m owner --uid-owner "$DEVELOPER_UID" -p tcp --dport 53 -j ACCEPT

  # Allow developer: api.anthropic.com:443 only
  for IP in $ANTHROPIC_IPS; do
    iptables -A OUTPUT \
      -m owner --uid-owner "$DEVELOPER_UID" \
      -d "$IP" -p tcp --dport 443 -j ACCEPT
  done

  # Drop all other developer outbound traffic
  iptables -A OUTPUT -m owner --uid-owner "$DEVELOPER_UID" -j DROP

  # Persist rules across reboots via netfilter-persistent
  netfilter-persistent save
  echo "INFO: iptables rules saved to /etc/iptables/rules.v4"
fi

# ============================================================
# Section 19: JupyterLab systemd service
# ============================================================
echo ">>> [19/20] Installing JupyterLab systemd service..."

cat > /etc/systemd/system/jupyterlab.service << 'UNIT'
[Unit]
Description=JupyterLab — medimg-env PHI-safe development
After=network.target

[Service]
Type=simple
User=developer
Group=developer
WorkingDirectory=/workspace
Environment="PATH=/opt/medimg-env/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="CLAUDE_CODE_ROOTDIR=/workspace"
Environment="DISABLE_AUTOUPDATER=1"
# Set ANTHROPIC_API_KEY via: sudo systemctl edit jupyterlab.service
# Then add: Environment="ANTHROPIC_API_KEY=sk-ant-..."
ExecStart=/opt/medimg-env/venv/bin/jupyter lab \
    --ip=127.0.0.1 \
    --port=8888 \
    --no-browser \
    --ServerApp.token='' \
    --ServerApp.password=''
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable jupyterlab.service
echo "INFO: JupyterLab service installed and enabled."
echo "      Start with: sudo systemctl start jupyterlab"
echo "      Access via SSH tunnel: ssh -L 8888:127.0.0.1:8888 <user>@<host>"

# ============================================================
# Section 20: Verification summary
# ============================================================
echo ""
echo "====================================================="
echo "  INSTALLATION COMPLETE — Verification"
echo "====================================================="
echo ""
echo "Node.js  : $(node --version)"
echo "npm      : $(npm --version)"
echo "Python   : $("$VENV_DIR/bin/python" --version)"
echo "pip      : $("$VENV_DIR/bin/pip" --version | cut -d' ' -f1-2)"
echo "Claude   : $(claude --version 2>&1 | head -1)"
echo "Jupyter  : $("$VENV_DIR/bin/jupyter" --version 2>&1 | head -1)"
echo "PyTorch  : $("$VENV_DIR/bin/python" -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'import failed')"
echo "MONAI    : $("$VENV_DIR/bin/python" -c 'import monai; print(monai.__version__)' 2>/dev/null || echo 'import failed')"
echo "SimpleITK: $("$VENV_DIR/bin/python" -c 'import SimpleITK; print(SimpleITK.Version_VersionString())' 2>/dev/null || echo 'import failed')"
echo ""
echo "developer uid    : $(id developer)"
echo "settings.json    : $(ls -la /home/developer/.claude/settings.json)"
echo "audit log        : $(ls -la /var/log/claude-audit.log)"
echo "jupyterlab svc   : $(systemctl is-enabled jupyterlab 2>/dev/null)"
echo ""
echo "iptables OUTPUT rules:"
iptables -L OUTPUT -n --line-numbers 2>/dev/null || echo "(iptables not configured)"
echo ""
echo "====================================================="
echo "  NEXT STEPS"
echo "====================================================="
echo ""
echo "1. Set ANTHROPIC_API_KEY for the developer user:"
echo "   sudo -u developer bash -c 'echo export ANTHROPIC_API_KEY=sk-ant-... >> ~/.bashrc'"
echo "   OR for the systemd service (recommended):"
echo "   sudo systemctl edit jupyterlab.service"
echo "   (add the line: Environment=\"ANTHROPIC_API_KEY=sk-ant-...\")"
echo ""
echo "2. Start JupyterLab:"
echo "   sudo systemctl start jupyterlab"
echo ""
echo "3. Access JupyterLab via SSH tunnel:"
echo "   ssh -L 8888:127.0.0.1:8888 <user>@$(hostname -I | awk '{print $1}')"
echo "   Then open: http://127.0.0.1:8888"
echo ""
echo "4. Verify network restrictions:"
echo "   sudo bash $SCRIPT_DIR/test-network.sh"
echo ""
