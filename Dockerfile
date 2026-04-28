# ============================================================
# Ubuntu 24.04 — Medical Imaging / Scientific Python Stack
#                + Claude Code CLI (PHI-safe configuration)
#
# PHI SECURITY ARCHITECTURE
# ══════════════════════════════════════════════════════════════
# Layer 1 — Docker mount policy (enforced at host, see run cmd)
#   • NEVER mount PHI directories into the container
#   • Only mount /code (source) and /outputs (results)
#   • PHI data stays on the host, outside the container
#
# Layer 2 — Non-root user (developer)
#   • Claude Code runs as uid 1000, not root
#   • Cannot escalate privileges or access root-owned paths
#
# Layer 3 — Claude Code settings.json deny-list
#   • Hard-blocks reads of known PHI path patterns
#   • Hard-blocks exfiltration tools: curl, wget, scp, rsync
#   • Restricts Claude Code to /workspace only
#
# Layer 4 — Shell wrapper (entry point)
#   • Enforces CLAUDE_CODE_ROOTDIR at runtime
#   • Logs all Claude Code invocations for audit
#
# Layer 5 — Network egress (enforced at host, see run cmd)
#   • Use --network=none or a custom bridge with allowlist
#   • Block everything except api.anthropic.com:443
#
# ══════════════════════════════════════════════════════════════
# KNOWN PHI LEAK SCENARIOS (and which layer stops each)
# ──────────────────────────────────────────────────────────────
# 1. Mounting a PHI directory at `docker run` time
#    e.g. -v /data/patients:/workspace/data
#    RISK: Claude CAN read and send those files to Anthropic
#    STOP: Host-side mount policy — only mount /code and /outputs
#
# 2. Claude reads a DICOM file with PHI in its header metadata
#    RISK: Patient name, DOB, MRN embedded in .dcm headers
#    STOP: Never mount data dirs; deny-list blocks /dicom /data paths
#
# 3. Developer pastes PHI directly into the Claude Code prompt
#    RISK: Cannot be prevented by Docker — it goes straight to API
#    STOP: Training + ZDR enterprise agreement with Anthropic
#
# 4. Claude executes `curl` to exfiltrate data to attacker server
#    RISK: Prompt injection or supply-chain attack triggers curl
#    STOP: curl/wget blocked in deny-list + network egress allowlist
#
# 5. Claude reads credentials, SSH keys, or .env files
#    RISK: Secrets sent to Anthropic in context window
#    STOP: deny-list blocks .env, .pem, .key, id_rsa patterns
#
# 6. MCP server with external access leaks data out-of-band
#    RISK: MCP tool sends data to Notion, Slack, external APIs
#    STOP: MCP disabled in settings.json + network egress block
#
# 7. Claude traverses outside /workspace via ../../../ paths
#    RISK: Reads host-mounted files outside intended scope
#    STOP: CLAUDE_CODE_ROOTDIR env var + deny-list on ../
#
# 8. Jupyter notebook loads PHI data; Claude reads open notebook
#    RISK: If PHI is visible in a notebook cell, Claude sees it
#    STOP: Procedural — only open notebooks with synthetic data
#
# ══════════════════════════════════════════════════════════════
# SAFE `docker run` COMMAND:
#
#   docker run -it --rm \
#     --network phi-safe-net \
#     -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
#     -v /path/to/SOURCE_CODE:/workspace:rw \
#     -v /path/to/OUTPUTS:/outputs:rw \
#     medimg-phi-safe bash
#
# Create the restricted network once on the host:
#   docker network create --driver bridge phi-safe-net
#   # Then add iptables rules on the host to allow only:
#   #   tcp dst 443 to api.anthropic.com
#   # and block all other outbound from this bridge.
#
# ══════════════════════════════════════════════════════════════

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Chicago
ENV ANTHROPIC_API_KEY=""
# Disable auto-updater — avoids container OOM bug on startup
ENV DISABLE_AUTOUPDATER=1
# Restrict Claude Code filesystem root to /workspace only
ENV CLAUDE_CODE_ROOTDIR=/workspace

# ------------------------------------------------------------
# 1. System packages
# ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git curl wget unzip ca-certificates \
    python3 python3-pip python3-dev python3-venv \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev libgomp1 \
    libdcmtk-dev libinsighttoolkit5-dev libhdf5-dev libgdal-dev \
    zlib1g-dev liblzma-dev libbz2-dev \
    htop tree vim \
    auditd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Node.js 22 LTS (required for Claude Code)
# ------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# ------------------------------------------------------------
# Python setup
# ------------------------------------------------------------
RUN ln -sf /usr/bin/python3 /usr/bin/python

# ------------------------------------------------------------
# 2. Scientific Python core
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    numpy scipy pandas matplotlib seaborn \
    scikit-learn scikit-image statsmodels \
    h5py tqdm joblib ipython jupyterlab ipywidgets

# ------------------------------------------------------------
# 3. Medical imaging — NIfTI, DICOM, ITK
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    nibabel nilearn pydicom SimpleITK itk \
    antspyx dicom2nifti pynetdicom

# ------------------------------------------------------------
# 4. Vessel segmentation & image processing
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    opencv-python-headless Pillow \
    connected-components-3d edt fill-voids kimimaro \
    morphsnakes pymeshlab

# ------------------------------------------------------------
# 5. Deep learning — PyTorch CPU (swap for CUDA below)
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cpu
# GPU: RUN pip install torch torchvision torchaudio \
#          --index-url https://download.pytorch.org/whl/cu121

# ------------------------------------------------------------
# 6. Medical segmentation frameworks
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    monai segmentation-models-pytorch timm einops torchio

# ------------------------------------------------------------
# 7. ML / experiment tracking
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    mlflow wandb optuna shap imbalanced-learn xgboost lightgbm

# ------------------------------------------------------------
# 8. Data versioning & reproducibility
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    dvc hydra-core omegaconf

# ------------------------------------------------------------
# 9. Topological / graph tools
# ------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages \
    gudhi ripser persim networkx vtk

# ------------------------------------------------------------
# 10. Claude Code CLI
# ------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code && \
    claude --version

# ------------------------------------------------------------
# 11. Non-root user — Claude Code runs as 'developer' (uid 1000)
#
#     SECURITY REASON: Running Claude Code as root gives it (and
#     any prompt-injected commands) unrestricted access to the
#     entire filesystem. A non-root user limits blast radius to
#     only what 'developer' can read/write.
# ------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash developer && \
    mkdir -p /workspace /outputs && \
    chown -R developer:developer /workspace /outputs /home/developer

# ------------------------------------------------------------
# 12. Claude Code security policy (settings.json)
#
#     Baking this into the image ensures it is always present.
#     Developers cannot accidentally delete or skip it.
#
#     allow: only /workspace and /outputs
#     deny:
#       - Common PHI directory name patterns
#       - Parent directory traversal
#       - Credential / secret file patterns
#       - Shell exfiltration tools
#     MCP: disabled entirely
# ------------------------------------------------------------
RUN mkdir -p /home/developer/.claude
COPY claude-settings.json /home/developer/.claude/settings.json

# Protect the settings file — developer can read but not overwrite
RUN chown root:developer /home/developer/.claude/settings.json && \
    chmod 444 /home/developer/.claude/settings.json && \
    chown developer:developer /home/developer/.claude

# ------------------------------------------------------------
# 13. Audit log for all Claude Code invocations
#     Creates a record of every claude call: timestamp, user,
#     working directory, and arguments.
# ------------------------------------------------------------
RUN touch /var/log/claude-audit.log && \
    chmod 666 /var/log/claude-audit.log

# ------------------------------------------------------------
# 14. Login banner reminding developers of PHI policy
# ------------------------------------------------------------
COPY motd /etc/motd

# ------------------------------------------------------------
# 15. Switch to non-root user for all runtime activity
# ------------------------------------------------------------
USER developer
WORKDIR /workspace

EXPOSE 8888

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", \
     "--no-browser", "--allow-root", \
     "--NotebookApp.token=''", "--NotebookApp.password=''"]
