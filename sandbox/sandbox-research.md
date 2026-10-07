# Create a sandbox environment using podman

Podman has a built-in, secure credential manager called Podman Secrets. It encrypts your keys on your Mac's backend Podman Machine and mounts them into the container as temporary, in-memory files (tmpfs). They never touch the container's actual hard drive storage.

Example:
```sh
podman secret create openai_key - <<< "sk-proj-xxxxxx"
podman secret create github_ssh_key ~/.ssh/id_ed25519

```

Mount the secrets into the sandbox:

```sh
podman run -it --rm \
  --secret openai_key,type=env,target=OPENAI_API_KEY \
  --secret github_ssh_key,target=/home/podman/.ssh/id_ed25519 \
  -v ~/Desktop/ai-workspace:/workspace:rw \
  quay.io/podman/stable bash

```

* The openai_key is turned directly into an environment variable (OPENAI_API_KEY) inside the container without ever existing as a file.
* The github_ssh_key is mounted as a file at /home/podman/.ssh/id_ed25519, but it exists entirely in RAM. The moment the container stops or exits, that file completely vanishes from existence. 

## Build the image

Create a file named Containerfile:

```sh
FROM quay.io/podman/stable

ARG USER_NAME=ai-agent
ARG USER_UID=2001

# Switch to root temporarily to configure the new user
USER root

# Create the custom group and user
RUN groupadd -g ${USER_UID} ${USER_NAME} && \
    useradd -u ${USER_UID} -g ${USER_UID} -m -s /bin/bash ${USER_NAME}

# Set the working directory and switch permanently to your custom user
WORKDIR /workspace
USER ${USER_NAME}
```

Build the image:

```sh
podman build \
  --build-arg USER_NAME="mycoder" \
  --build-arg USER_UID="1500" \
  -t mac-ai-sandbox-custom .
```

Run the container based on the image:

```sh
#!/usr/bin/env bash

WORKSPACE_DIR="$HOME/Desktop/ai-workspace"
SSH_KEY_SRC="$HOME/.ssh/id_ed25519"
CUSTOM_USER="mycoder" # Must match what you built above

mkdir -p "$WORKSPACE_DIR"

podman run -it --rm \
  --name mac-ai-sandbox \
  --device /dev/fuse \
  --cap-drop=ALL \
  -e OPENAI_API_KEY \
  -e ANTHROPIC_API_KEY \
  -v "$WORKSPACE_DIR":/workspace:rw \
  -v "$SSH_KEY_SRC":/home/"$CUSTOM_USER"/.ssh/id_ed25519:ro \
  --workdir /workspace \
  mac-ai-sandbox-custom bash
```

**--device /dev/fuse** : Podman relies on a storage driver called fuse-overlayfs to overlay container filesystems on top of each other. 
Without access to /dev/fuse, you would get a "Permission Denied" error the second it tried to run a command like podman run or podman build.

**--cap-drop=ALL** : This strips away every single Linux Kernel Capability from the container processes. Probably a bit too harsh for our purposes.

**--workdir /workspace** : This sets the default starting directory inside the container when the terminal session boots up.

**--network none** : This completely strips the network stack from the container process. Too harsh for us

## podman network create --internal my-mesh

The --internal flag explicitly tells Podman to disable default masquerading or external routing tables for this bridge network.

Launch the container Launch your script container with this network: `--network my-mesh`

**--network="pasta:-a,10.0.2.0,-g,10.0.2.2"** : This specific switch configures Podman to use pasta (the ultra-secure, rootless network driver used by default in modern Podman) and passes specific parameters to it to manually control the container's internal IP addresses.

Here is exactly what those parameters mean:
• pasta: Tells Podman to use the Pasta network stack (Packets AS-is Transit Agenda) rather than traditional rootless tools like slirp4netns.
• -a, 10.0.2.0 (Address): Assigns the private IP network block 10.0.2.0 to the container's internal network interface.
• -g, 10.0.2.2 (Gateway): Explicitly designates 10.0.2.2 as the container's default gateway (the door it uses to send packets out to the internet).

**--network="pasta:--no-map-gw"** : tell Pasta not to copy your Mac's default internet routing table by omitting a gateway, effectively isolating the container while keeping internal interfaces active

**--network="pasta:--dns,127.0.0.1"** : force the sandbox to use a completely non-existent or heavily filtered DNS server. Because 127.0.0.1 points to itself, the AI agent's network requests will instantly fail to resolve any domain names like malicious-server.com, effectively blinding its ability to reach unauthorized web services

The string --network="pasta:-a,10.0.2.0,-g,10.0.2.2" is simply a manual static network configuration. To turn it into a security feature, you want to combine it with Pasta's isolation flags (like --no-map-gw or --dns) to strip away the ability to browse the web freely.

