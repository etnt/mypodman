#!/bin/bash
# Dynamic user creation entrypoint for container compatibility

# Get the current UID/GID
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
CURRENT_USER=$(whoami 2>/dev/null || echo "user${CURRENT_UID}")

# If we don't have a username (running as numeric UID), create user entry
if [ "$CURRENT_USER" = "user${CURRENT_UID}" ] || ! id "$CURRENT_USER" &>/dev/null; then
    echo "Creating user entry for UID:GID ${CURRENT_UID}:${CURRENT_GID}"
    
    # Create group if it doesn't exist
    if ! getent group "$CURRENT_GID" &>/dev/null; then
        sudo groupadd -g "$CURRENT_GID" "group${CURRENT_GID}" 2>/dev/null || true
    fi
    
    # Create or modify user
    if ! getent passwd "$CURRENT_UID" &>/dev/null; then
        sudo useradd -u "$CURRENT_UID" -g "$CURRENT_GID" -m -s /bin/bash "$CURRENT_USER" 2>/dev/null || true
    fi
    
    # Ensure sudo access
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$CURRENT_USER" >/dev/null 2>&1 || true
fi

# Execute the command passed to the container
exec "$@"
