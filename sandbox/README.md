# Podman development sandbox

The sandbox runs development tools in Debian Testing, a Linux distribution. Podman starts a container with a name. A container is an isolated environment with its own files and processes. Podman mounts the current directory as the home directory of the container user.

## Quick start

1. Install Podman. Then start the Podman service or Podman Machine.
2. Build the image:

   ```sh
   ./sandbox/sandbox-wizard.sh build
   ```

3. Change to the project directory that you want to mount.
4. Create the sandbox:

   ```sh
   ./sandbox/sandbox-wizard.sh create
   ```

5. Enter the running sandbox. Replace `<container-name>` with the name of your sandbox:

   ```sh
   ./sandbox/sandbox-wizard.sh enter <container-name>
   ```

Run `./sandbox/sandbox-wizard.sh help` to see the list of commands. Run the wizard without a command to open its menu. Put `--dry-run` before a command to print the Podman commands without running them.

## Image contents

The image uses `debian:testing-slim`. It includes these tools:

- C build tools, Erlang, Node.js, and Python
- `sudo`, Git, jj, Helix, GitHub CLI, GitHub Copilot CLI, and pi
- ripgrep (`rg`), fd (`fd`), and common shell and SSH tools

The image installs ripgrep and fd from Debian packages. pi uses them without a download. A download fails because the sandbox has no direct network access.

The default user name is `dev`. The image user has UID and GID 1000. UID and GID are the numeric IDs of a user and a group. The wizard uses these IDs for Podman's `keep-id` mapping. Do not change them without also changing the run command.

The image installs `gh` from the signed Debian repository of GitHub. It pins these versions:

- Node.js 24.21.0
- Copilot CLI 1.0.93
- pi 1.1.0
- Helix 25.07.1

To choose another release, set the build argument `NODE_VERSION`, `COPILOT_CLI_VERSION`, `PI_VERSION`, or `HELIX_VERSION`.

To reduce image size, Helix keeps grammars for the requested languages and common project files. A grammar is the set of syntax rules for one language.

The build command also builds the credential proxy image. The credential proxy is a separate container that sends API requests for the sandbox. See [API and SSH secrets](#api-and-ssh-secrets).

pi comes from the `@earendil-works/pi-coding-agent` package. It installs in `/opt/pi`, which the sandbox user owns. To update pi, run `pi update` in the sandbox. The update works through the credential proxy. The proxy permits `pi.dev` and `registry.npmjs.org`. A rebuilt image returns pi to the pinned version.

GitHub CLI and Copilot CLI can save authentication data in the mounted home. When the credential proxy is active, pi stores its provider configuration and sessions in the container at `/var/lib/sandbox/pi-agent`.

Do not use the pi `/login` command with a real API key. The key would be readable inside the sandbox. Before you commit the project, review the `.config` and `.copilot` directories.

## Workspace mode and identity

Choose `map` to mount the current host directory at `/home/<user>`. The host is your computer. Changes on the host and in the container affect the same files. The wizard warns you if you choose the host home directory.

Choose `clone` to copy the current directory into the container home. The copy includes hidden files. Later changes on the host do not appear in the container. Before you clone, review files such as `.env`. The container receives their contents.

Clone mode does not mount the host directory. The copy stays in the writable layer of the container. This layer is the storage that Podman adds on top of the image. Removing the container deletes the copy. To keep the copy, use `commit` to save the container as an image.

The container user name must match the name that you used to build the image. To use a different name, rebuild the image. During sandbox creation, enter your Git name and email. The wizard writes them to the Git and jj configuration in the workspace.

On Linux, map mode adds the `:Z` volume option for SELinux. SELinux is a security system for Linux. On macOS, Podman uses its machine to share host directories. Large mapped projects can run more slowly through this shared mount.

## API and SSH secrets

The wizard supports two API keys: `OPENROUTER_API_KEY` and `OPENAI_API_KEY`. Export a key before you create the sandbox:

```sh
export OPENROUTER_API_KEY=your-key
./sandbox/sandbox-wizard.sh create
```

The wizard creates a credential proxy for every sandbox. It asks whether to route each supported API key through the proxy. It shows only the variable names. For each selected key, the wizard stores the key as a Podman secret. A Podman secret is a value that Podman stores for containers to use. The wizard mounts the secret into the trusted credential proxy container.

The sandbox receives a fake token and the address of the proxy. The real key does not enter the sandbox environment or file system. Podman keeps the key in its secret store. The proxy container reads the key from there.

The wizard saves a private configuration file in `~/.config/sandbox-wizard/`. The file stores secret names and proxy details. It does not store API key values.

The sandbox has no network interface except loopback. Loopback is the internal network address `127.0.0.1` on a machine. The credential proxy listens on a Unix socket. A Unix socket is a file that programs on the same machine use to communicate. The socket is in a volume that only the proxy and its sandbox share. A bridge program in the sandbox listens on `127.0.0.1:8765`. It passes traffic to the socket.

The sandbox cannot connect directly to the internet or to the Podman gateway. The proxy forwards API requests to the selected provider. It permits HTTPS connections to selected GitHub hosts and to these hosts:

- `registry.npmjs.org`
- `pypi.org`
- `files.pythonhosted.org`
- `deb.debian.org`
- `security.debian.org`
- `nodejs.org`
- `pi.dev`

The proxy rejects other destinations. These routes work even if you do not select an API key.

The proxy lets sandbox code use the selected API key. Code can spend the quota of the key through the proxy, but it cannot read the key. Set a spending limit for each key at the provider.

The wizard does not pass other `*_API_KEY` variables into the sandbox. The isolated proxy does not support them, and the wizard reports this.

The SSH private key works differently. SSH is a protocol for secure remote logins. The wizard mounts the SSH private key into the sandbox as a read-only secret at `/home/<user>/.ssh/id_ed25519`. Code in the sandbox can read this key. The proxy routes SSH traffic to GitHub. It does not hide the private key.

List or remove stored Podman secrets with these commands:

```sh
./sandbox/sandbox-wizard.sh secrets ls
./sandbox/sandbox-wizard.sh secrets rm <secret-name>
```

The list shows the secrets on the current Podman connection. It does not show which container uses each secret. Stop a sandbox before you remove it. Removing a sandbox removes its credential proxy, its socket volume, its API key and token secrets, and its saved configuration. The SSH secret stays in Podman.

Existing sandboxes do not receive these changes. Remove and recreate each sandbox that received a real API key. After no container uses an old API key secret, remove that secret. If untrusted code can read a key, rotate the key. To rotate a key means to create a new key and disable the old one.

## Container commands

```sh
./sandbox/sandbox-wizard.sh ps             # List running sandboxes
./sandbox/sandbox-wizard.sh ps all         # List all sandboxes
./sandbox/sandbox-wizard.sh start <name>
./sandbox/sandbox-wizard.sh stop <name>
./sandbox/sandbox-wizard.sh rm <name>
./sandbox/sandbox-wizard.sh commit <name> <image-tag>
./sandbox/sandbox-wizard.sh configs ls
```

The `commit` command saves the changes in the container layer as a new image. In map mode, files in the mounted project directory are not part of that image. In clone mode, the copied workspace is part of the container layer, so the commit saves it.

## Network access

The sandbox runs with `--network none`. It cannot make direct network connections. HTTPS requests pass through the loopback bridge to the credential proxy. The wizard checks this isolation after it creates a sandbox. The proxy permits OpenAI and OpenRouter API routes, selected GitHub hosts, and package registries. It rejects other destinations.
