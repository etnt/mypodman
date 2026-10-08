# Podman development sandbox

This sandbox runs development tools in Debian Testing. Podman starts a named container and mounts the current directory as the container user's home.

## Quick start

1. Install Podman and start its service or Podman Machine.
2. Build the image:

   ```sh
   ./sandbox/sandbox-wizard.sh build
   ```

3. Change to the project directory that you want to mount.
4. Create the sandbox:

   ```sh
   ./sandbox/sandbox-wizard.sh create
   ```

5. Enter the running sandbox:

   ```sh
   ./sandbox/sandbox-wizard.sh enter <container-name>
   ```

Run `./sandbox/sandbox-wizard.sh help` to see the command list. Run the wizard without a command to open its menu. Use `--dry-run` before a command to print Podman commands without running them.

## Image contents

The image uses `debian:testing-slim`. It includes C build tools, Erlang, Node.js, Python, `sudo`, Git, jj, Helix, GitHub CLI, GitHub Copilot CLI, pi, ripgrep (`rg`), fd (`fd`), and common shell and SSH tools. ripgrep and fd come from Debian packages. pi uses them without a download, which would fail because the sandbox has no direct network access. The user name defaults to `dev`. The image user has UID and GID 1000. The wizard uses these IDs for Podman's `keep-id` mapping, so do not change them without changing the run command too.

The image installs `gh` from GitHub's signed Debian repository. It pins Node.js 24.21.0, Copilot CLI 1.0.93, pi 0.73.1, and Helix 25.07.1. Set the `NODE_VERSION`, `COPILOT_CLI_VERSION`, `PI_VERSION`, or `HELIX_VERSION` build argument to choose another release. To reduce image size, Helix keeps grammars for the requested languages and common project files. The build command also builds the credential proxy image.

GitHub CLI and Copilot CLI can save authentication data under the mounted home. When the API proxy is active, pi stores its provider configuration and sessions in the container at `/var/lib/sandbox/pi-agent`. Do not use pi `/login` with a real API key. That key would be readable inside the sandbox. Review `.config` and `.copilot` before you commit the project.

## Workspace mode and identity

Choose `map` to mount the current host directory at `/home/<user>`. Host and container changes then affect the same files. The wizard warns if you choose the host home directory.

Choose `clone` to copy the current directory into the container home. The copy includes hidden files. Later host changes do not appear in the container. Review files such as `.env` before you clone because the container receives their contents.

Clone mode does not mount the host directory. The copy stays in the container's writable layer. Removing the container deletes that copy. Use `commit` to save it as an image.

The container user name must match the name used to build the image. Rebuild the image if you need a different container user name. During sandbox creation, enter your Git name and email. The wizard writes them to Git and jj's user configuration in the workspace.

On Linux, map mode adds the `:Z` volume option for SELinux. On macOS, Podman uses its machine to share host directories. Large mapped projects can run more slowly through this shared mount.

## API and SSH secrets

The wizard supports `OPENROUTER_API_KEY` and `OPENAI_API_KEY`. Export a key before you create the sandbox:

```sh
export OPENROUTER_API_KEY=your-key
./sandbox/sandbox-wizard.sh create
```

The wizard creates a credential proxy for every sandbox. It asks whether to route each supported API key through that proxy. It displays variable names only. It stores each selected key as a Podman secret and mounts it into the trusted proxy container. The sandbox receives a fake token and a proxy address. The real key does not enter the sandbox environment or file system. Podman keeps the key in its secret store and the proxy container reads it.

The wizard saves a private configuration file in `~/.config/sandbox-wizard/`. The file stores secret names and proxy details. It does not store API key values.

The sandbox has no network interface except loopback. The proxy container listens on a Unix socket in a volume that only the proxy and its sandbox share. A bridge program in the sandbox listens on `127.0.0.1:8765` and passes traffic to that socket. The sandbox cannot connect directly to the internet or to the Podman gateway. The proxy forwards API requests to the selected provider. It permits HTTPS connections to selected GitHub hosts, `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `deb.debian.org`, `security.debian.org`, and `nodejs.org`. Other destinations fail. These routes work even if you do not select an API key.

The proxy lets sandbox code use the selected API key. Code can spend the key's quota through the proxy, but it cannot read the key. Set provider limits on each key.

Other `*_API_KEY` variables are not passed into the sandbox. The wizard reports that the isolated proxy does not support them.

The SSH private key is different. The wizard mounts it into the sandbox as a read-only secret at `/home/<user>/.ssh/id_ed25519`. Code in the sandbox can read that key. The proxy routes SSH traffic to GitHub, but it does not hide the private key.

List or remove stored Podman secrets with:

```sh
./sandbox/sandbox-wizard.sh secrets ls
./sandbox/sandbox-wizard.sh secrets rm <secret-name>
```

This list shows stored secrets on the current Podman connection. It does not show which container uses each secret. Stop a sandbox before you remove it. Removing a sandbox removes its proxy, its socket volume, its API-key and token secrets, and its saved configuration. The SSH secret remains in Podman.

This change does not update existing sandboxes. Remove and recreate any sandbox that received a real API key. Remove old API-key secrets after no container uses them. Rotate a key if untrusted code could read it.

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

A commit saves changes in the container layer as a new image. In map mode, files in the mounted project directory are not part of that image. In clone mode, the copied workspace is part of the container layer.

## Network access

The sandbox runs with `--network none`. It cannot make direct network connections. HTTPS requests pass through a loopback bridge to the credential proxy. The wizard checks this isolation after it creates a sandbox. The proxy permits OpenAI and OpenRouter API routes, selected GitHub hosts, and package registries. It rejects other destinations.
