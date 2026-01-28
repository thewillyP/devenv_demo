#!/bin/bash
set -euo pipefail

BASHRC="${HOME}/.bashrc"
DOCKER_SOURCE='source /.singularity.d/env/10-docker2singularity.sh'
LIB_EXPORT='export LD_LIBRARY_PATH="/.singularity.d/libs"'

# Create .bashrc if it doesn't exist
[ -f "$BASHRC" ] || touch "$BASHRC"

# Add docker2singularity source line if not already present
grep -qxF "$DOCKER_SOURCE" "$BASHRC" || echo "$DOCKER_SOURCE" >> "$BASHRC"

# Add LD_LIBRARY_PATH export if not already present
grep -qxF "$LIB_EXPORT" "$BASHRC" || echo "$LIB_EXPORT" >> "$BASHRC"

# Source .bashrc to apply changes in the current session
source "$BASHRC"

# Launch Jupyter notebook
mkdir -p "${HOME}/notebooks"
jupyter lab --notebook-dir="${HOME}/notebooks" --ip="0.0.0.0" --port=8888 --no-browser --allow-root &

### SSH Server

# Fakeroot fixes (silent fail if not in fakeroot)
# 1. Remap sshd user to uid 0 (fixes privsep security check)
sed -i 's/^sshd:x:100:65534:/sshd:x:0:0:/' /etc/passwd 2>/dev/null || true
# 2. Tar wrapper to skip chown (fixes tar for VS Code server and any other tarballs)
(
cat > /usr/local/bin/tar << 'EOF'
#!/bin/bash
exec /bin/tar --no-same-owner "$@"
EOF
chmod +x /usr/local/bin/tar
) 2>/dev/null || true

# Dynamically generate sshd keys for the ssh server
mkdir -p ~/hostkeys
[ -f ~/hostkeys/ssh_host_rsa_key ] || ssh-keygen -q -N "" -t rsa -b 4096 -f ~/hostkeys/ssh_host_rsa_key

exec /usr/sbin/sshd -D -p 2001 \
    -o PermitUserEnvironment=yes \
    -o PermitTTY=yes \
    -o X11Forwarding=yes \
    -o AllowTcpForwarding=yes \
    -o GatewayPorts=yes \
    -o ForceCommand=/bin/bash \
    -o UsePAM=no \
    -h ~/hostkeys/ssh_host_rsa_key
