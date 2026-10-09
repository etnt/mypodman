# Podman development sandbox

The sandbox runs development tools in Debian Testing, a Linux distribution. Podman starts a container with a name. A container is an isolated environment with its own files and processes.

The sandbox container uses one of two workspace modes. You choose the mode when you create the sandbox:

- **Map mode.** Podman mounts the current directory as the home directory of the container user. The container and the host share the same files. Changes on one side appear on the other side.
- **Clone mode.** Podman does not mount the host directory. Instead, the wizard makes a one-time copy of the current directory in the container home. The copy includes hidden files, such as `.env`. Code in the container can read everything in the copy. After the copy, the host and the container do not share changes. Removing the container deletes the copy.

The sandbox does not hold your real API keys. A separate credential proxy container holds them. The proxy forwards API requests for the sandbox and adds the real key to each request. The sandbox only gets a fake token. See [How the sandbox and the credential proxy work together](#how-the-sandbox-and-the-credential-proxy-work-together).

## Quick start

1. Install Podman. Then start the Podman service or Podman Machine.
2. Build the image:

   ```sh
   ./sandbox/sandbox-wizard.sh build
   ```

3. Change to the project directory that you want to use in the sandbox.
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

The build command also builds the credential proxy image. The wizard uses this image to start the credential proxy container. See [How the sandbox and the credential proxy work together](#how-the-sandbox-and-the-credential-proxy-work-together).

pi comes from the `@earendil-works/pi-coding-agent` package. It installs in `/opt/pi`, which the sandbox user owns. To update pi, run `pi update` in the sandbox. The update works through the credential proxy. The proxy permits `pi.dev` and `registry.npmjs.org`. A rebuilt image returns pi to the pinned version.

GitHub CLI and Copilot CLI can save authentication data in the mounted home. When the credential proxy is active, pi stores its provider configuration and sessions in the container at `/var/lib/sandbox/pi-agent`.

Do not use the pi `/login` command with a real API key. The key would be readable inside the sandbox. Before you commit the project, review the `.config` and `.copilot` directories.

## Workspace mode and identity

In map mode, Podman mounts the current host directory at `/home/<user>`. The host is your computer. The wizard warns you if the current directory is your host home directory.

In clone mode, the copy stays in the writable layer of the container. This layer is the storage that Podman adds on top of the image. Before you clone, review files such as `.env`. The container receives their contents. To keep the copy after you remove the container, use `commit` to save the container as an image.

The container user name must match the name that you used to build the image. To use a different name, rebuild the image. During sandbox creation, enter your Git name and email. The wizard writes them to the Git and jj configuration in the workspace.

On Linux, map mode adds the `:Z` volume option for SELinux. SELinux is a security system for Linux. On macOS, Podman uses its machine to share host directories. Large mapped projects can run more slowly through this shared mount.

## How the sandbox and the credential proxy work together

Each sandbox uses two containers. Each container has one job.

- **The sandbox container** runs your tools, such as pi, Git, and your code. It has no internet access. It does not have your real API keys.
- **The credential proxy container** holds your real API keys. It forwards allowed requests to the API provider or to GitHub. It adds the real key to each API request. It does not show the key to the sandbox.

The two containers share a Podman volume. A volume is storage that Podman keeps outside a container. Only these two containers use this volume. Inside the volume is a Unix socket. A Unix socket is a special file that two programs on the same machine use to send data to each other. This socket is the only way for the sandbox to reach the proxy.

### What each container can see

| Item | Sandbox container | Credential proxy container |
| --- | --- | --- |
| Real API key | No | Yes. It reads the key from a read-only secret file. |
| Fake token | Yes. It is in `OPENROUTER_API_KEY` or `OPENAI_API_KEY`. | Yes. It checks each request against this token. |
| Network access | None. Only loopback works. | Outside access. It forwards only to allowed hosts. |
| Shared socket volume | Yes | Yes |
| SSH private key | Yes. It is mounted as a read-only secret. | No |

Loopback is the internal address `127.0.0.1`. Programs in the same container use it to talk to each other. It does not lead outside the container.

### The parts

- **Loopback bridge.** A small program runs inside the sandbox. It listens on `127.0.0.1:8765`. When a tool connects there, the bridge copies the data to the Unix socket. The wizard starts the bridge when it creates, starts, or enters a sandbox.
- **Proxy address.** The sandbox sets `HTTPS_PROXY` to `http://127.0.0.1:8765`. Git, GitHub CLI, and other tools use this setting. For API providers, the wizard sets the base URL to the bridge address. For example, `http://127.0.0.1:8765/openrouter/api/v1`.
- **Fake token.** The wizard creates a random token. It sends the token to the sandbox as the API key. The token has no value outside this sandbox. The proxy knows the token, so it can check each request.

### How an API request works

When pi calls OpenRouter, these steps happen:

1. Pi sends a request to `http://127.0.0.1:8765/openrouter/api/v1/...`. It uses the fake token as the key.
2. The loopback bridge copies the request to the Unix socket.
3. The proxy checks the fake token. If the token is wrong, the proxy returns `401`.
4. The proxy checks the request path. It accepts only the API paths that it knows. Other paths return `404`.
5. The proxy replaces the fake token with the real key. It reads the key from its secret file.
6. The proxy sends the request to `openrouter.ai` over HTTPS.
7. The response returns the same way to pi. The real key is not part of the response.

The sandbox can make API calls. It cannot read the real key.

### How a GitHub request works

Git and GitHub CLI use the proxy too. They send their traffic to `127.0.0.1:8765` because of `HTTPS_PROXY`. The proxy opens a tunnel only to a host on its list. A tunnel is a direct connection that passes data without changing it. The proxy does not add any key to GitHub requests. For SSH, the sandbox sends traffic to `github.com` on port 22 through the same bridge.

### What the proxy blocks

The proxy sends traffic only to hosts on its list. It refuses every other destination. The list includes these hosts:

- GitHub: `github.com` (SSH and HTTPS), `api.github.com`, `api.githubcopilot.com`, `codeload.github.com`, `cli.github.com`, `uploads.github.com`, and several GitHub download hosts
- Packages and updates: `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `deb.debian.org`, `security.debian.org`, `nodejs.org`, and `pi.dev`
- API providers: `openrouter.ai` and `api.openai.com`, only through the API paths that the proxy knows

The sandbox has no route to other places, such as other websites and the Podman gateway. Its requests to these places fail.

### Check the setup

Run these commands inside the sandbox:

```sh
printenv OPENROUTER_API_KEY
curl -i https://openrouter.ai
```

The first command prints the fake token, not the real key. The second command fails, because the sandbox has no direct internet access.

The wizard also runs a check after it creates a sandbox. The check confirms three things: loopback is the only network interface, a direct internet connection fails, and the proxy answers through the bridge. If the check fails, remove the sandbox with `rm`.

## API and SSH secrets

The sandbox never gets your real API keys. It gets a fake token. The proxy uses the real key for each request.

The wizard supports two API keys: `OPENROUTER_API_KEY` and `OPENAI_API_KEY`. Export a key before you create the sandbox:

```sh
export OPENROUTER_API_KEY=your-key
./sandbox/sandbox-wizard.sh create
```

When you create a sandbox, the wizard does these steps:

1. It shows the names of the supported keys. It does not show their values. You choose which keys to send through the proxy.
2. It stores each chosen key as a Podman secret. A Podman secret is a value that Podman keeps for containers. The wizard does not write the key to a file.
3. It creates a random fake token and stores it as a Podman secret.
4. It creates the credential proxy container. It mounts the real keys and the fake token as read-only files. Only the proxy container can read them.
5. It creates the sandbox container. It sets `OPENROUTER_API_KEY` or `OPENAI_API_KEY` to the fake token. It sets the matching base URL to the loopback bridge. It sets only the variables for the providers that you chose.
6. It connects the two containers through the shared socket volume.

The wizard saves a private configuration file in `~/.config/sandbox-wizard/`. The file stores secret names and proxy details. It does not store API key values or the fake token.

The wizard does not pass other `*_API_KEY` variables into the sandbox. The proxy does not support them. The wizard reports this.

### The SSH key works differently

The wizard mounts your SSH private key into the sandbox as a read-only secret. The path is `/home/<user>/.ssh/id_ed25519`. Code in the sandbox can read this key. The proxy does not hide it. The proxy only passes SSH traffic to `github.com`.

### Manage stored secrets

List or remove stored Podman secrets with these commands:

```sh
./sandbox/sandbox-wizard.sh secrets ls
./sandbox/sandbox-wizard.sh secrets rm <secret-name>
```

The list shows the secrets on the current Podman connection. It does not show which container uses each secret. Stop a sandbox before you remove it.

Removing a sandbox removes its credential proxy, its socket volume, its API key and token secrets, and its saved configuration. The SSH secret stays in Podman.

### Update an older sandbox

Older sandboxes do not get these changes. Remove and recreate each sandbox that received a real API key. After no container uses an old API key secret, remove that secret.

If untrusted code could read a key, rotate the key. To rotate a key, create a new key at the provider. Then disable the old key.

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

The wizard stops, starts, and removes the credential proxy with the sandbox. Use the wizard commands and not raw Podman commands. The wizard keeps the two containers in step.

The `commit` command saves the changes in the container layer as a new image. In map mode, files in the mounted project directory are not part of that image. In clone mode, the copied workspace is part of the container layer, so the commit saves it.

## Network access

The sandbox runs with `--network none`. It has no network interface except loopback. It cannot make direct network connections. All of its outside traffic goes through the loopback bridge to the credential proxy. The proxy sends traffic only to hosts on its list. For the list of allowed hosts, see [What the proxy blocks](#what-the-proxy-blocks).

Allowed hosts can still carry data out of the sandbox. For example, code can send files to a GitHub repository that you do not control. The proxy protects API keys. It does not stop code from sending files that it can read.

Set a spending limit for each API key at the provider. The sandbox can use the key through the proxy, so it can spend your quota.
