# User Namespace Handling in Podman

## The Problem
When running containers, you need to:
1. Have correct file permissions on mounted volumes (matching host UID/GID)
2. Run as a proper user inside the container
3. Handle conflicts when remote images have users with the same UID

## The Solution: User Namespace Remapping

### Option 1: `--userns=keep-id` (Recommended)
```bash
podman run --userns=keep-id ...
```
- Maps your host UID (501) into the container
- Files on mounted volumes have correct ownership
- Handles UID conflicts via separate namespaces
- Works with ANY remote image
- May show `I have no name!` prompt (cosmetic issue)

### Option 2: `--userns=keep-id:uid=X,gid=Y`
```bash
podman run --userns=keep-id:uid=1000,gid=1000 ...
```
- Maps your host UID to a specific container UID
- Useful when you want to run as a specific user in the container
- Files created show up as UID 1000 inside container, but your host UID outside

### Option 3: No user namespace (Not Recommended)
```bash
podman run ...
```
- Runs as whatever user the image specifies
- File permissions may be wrong on mounted volumes
- Security implications

## How UID Conflicts are Resolved

When a remote image has user "jenkins" with UID 9001, and you have host UID 501:

```
WITH --userns=keep-id:
  Host UID 501 → Mapped to container's existing user (e.g., UID 9001 "jenkins")
  You run AS that user inside the container
  Files on mounted volumes: Show as UID 501 on host, UID 9001 in container
  Both UIDs refer to YOU - just different namespaces
```

**Real example from your jenkins image:**
```bash
# On host
$ id
uid=501(ttornkvi) gid=20(staff)

# Inside container with --userns=keep-id
jenkins@container:/$ id
uid=9001(jenkins) gid=100(users)

# Same person, different namespace UIDs!
# Files you create are owned by:
#   - UID 501 on the host (your macOS user)
#   - UID 9001 inside container (jenkins user)
```

Podman intelligently maps your host UID to an **existing user in the image** if one exists,
giving you a proper username and home directory instead of "I have no name!"

## Your Host User Info
- Username: ttornkvi
- UID: 501
- GID: 20

## Updated Script Behavior
The `podman-wizard.sh` now asks which mapping strategy to use:
1. Auto-map (keep-id) - Recommended for most cases
2. Map to specific UID - When you need to match existing container users
3. No mapping - Only if you know what you're doing
