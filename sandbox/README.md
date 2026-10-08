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

The image uses `debian:testing-slim`. It includes C build tools, Erlang, Node.js, Python, `sudo`, Git, jj, Helix, GitHub CLI, GitHub Copilot CLI, pi, and common shell and SSH tools. The user name defaults to `dev`. The image user has UID and GID 1000. The wizard uses these IDs for Podman's `keep-id` mapping, so do not change them without changing the run command too.

The image installs `gh` from GitHub's signed Debian repository. It pins Node.js 24.21.0, Copilot CLI 1.0.93, pi 0.73.1, and Helix 25.07.1. Set the `NODE_VERSION`, `COPILOT_CLI_VERSION`, `PI_VERSION`, or `HELIX_VERSION` build argument to choose another release. To reduce image size, Helix keeps grammars for the requested languages and common project files.

GitHub CLI, Copilot CLI, and pi can save authentication data under the mounted home. Review `.config`, `.copilot`, and `.pi` before you commit the project.

## Mounted directory and identity

The wizard mounts the current host directory at `/home/<user>` and starts the shell there. Files created in the container remain in the host directory. The wizard warns if you try to mount your host home directory.

The container user name must match the name used to build the image. Rebuild the image if you need a different container user name. During sandbox creation, enter your Git name and email. The wizard writes them to Git and jj's user configuration in the mounted directory.

On Linux, the wizard adds the `:Z` volume option for SELinux. On macOS, Podman uses its machine to share host directories. Large projects can run more slowly through this shared mount.

## API and SSH secrets

The wizard can create Podman secrets while it creates a sandbox. It does not write secret values to the project or image. Podman manages the secret data on the Podman host. Treat that data as persistent until you remove the secret.

Before you create a sandbox, export the API keys that you want to offer:

```sh
export OPENAI_API_KEY=your-key
./sandbox/sandbox-wizard.sh create
```

The wizard finds exported variable names that contain `API_KEY`. It asks which names to pass into the sandbox. It displays names only. It reads each selected value from the environment and sends it to Podman without displaying it. The secret name defaults to the variable name. You can also add a key manually.

API secrets enter the container as environment variables. A process in the container can read those variables while it has access to the process environment. Do not use this method for keys that must stay hidden from code running in the sandbox.

The SSH private key enters the container as a read-only secret file at `/home/<user>/.ssh/id_ed25519`. The wizard sets the secret file owner and mode to UID 1000 and mode 0400. It creates the `.ssh` directory inside the mounted project directory. The wizard also creates an SSH configuration file there if one does not exist.

List and remove stored Podman secrets with:

```sh
./sandbox/sandbox-wizard.sh secrets ls
./sandbox/sandbox-wizard.sh secrets rm <secret-name>
```

The list shows secrets stored on the current Podman connection. It does not show which containers use each secret. Removing a secret can affect containers that use it. Podman can refuse to remove a secret that is in use.

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

A commit saves changes in the container layer as a new image. Files in the mounted project directory are not part of that image.

## Network access

The sandbox has normal network access. It does not apply network restrictions. The pasta options in `sandbox-research.md` are research notes for possible future hardening.
