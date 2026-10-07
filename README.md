# Podman Operations Wizard

An interactive, menu-driven script for managing Podman containers and images.

## Quick Start

Run the wizard:

```bash
./podman-wizard.sh
```

## Command-Line Usage

In addition to the interactive menu, the wizard can run a single command and exit:

```bash
./podman-wizard.sh help              # Show a compact list of commands and exit
./podman-wizard.sh <command> [args]  # Run a command and exit
```

Running the script with no arguments launches the interactive menu.

### Available Commands

| Command | Description |
| --- | --- |
| `help` | Show the command list and exit |
| `ps` | List running containers |
| `ps-all`, `psa` | List all containers (including stopped) |
| `images` | List images |
| `create` | Create and run a new container (interactive) |
| `enter <name> [shell]` | Exec into a container (default shell: `/bin/bash`) |
| `start <name>` | Start a stopped container |
| `stop <name>` | Stop a running container |
| `inspect <name>` | Show container details and mapped volumes |
| `rm <name>` | Remove a container |
| `commit <container> <image>` | Save a container as a new image |
| `tag <source> <target>` | Tag an image |
| `push <image>` | Push an image to a registry |
| `rmi <image>` | Remove an image |
| `configs` | Manage saved container configurations (interactive) |

Pass `--dry-run` (or `-n`) as the first argument to print a command instead of executing it:

```bash
./podman-wizard.sh --dry-run stop mycontainer
```

## Features

The wizard provides an easy-to-use menu interface for common Podman operations:

### Container Operations
- **List containers** - View running or all containers
- **Create and run new container** - Interactive setup with:
  - Image selection from local images or remote registry
  - Volume mapping options (home directory, current directory, custom paths)
  - Port mapping
  - Shell selection
  - Save configuration for reuse
- **Enter/exec into container** - Select from running containers and choose shell
- **Start stopped container** - Select from stopped containers
- **Stop running container** - Select from running containers  
- **Inspect container details** - View the image, status, ID, creation time, and command
- **Remove container** - Select from all containers with status indicators

### Image Operations
- **List images** - View all local images
- **Save container as new image (commit)** - Preserve container changes
- **Tag image** - Add tags to images for pushing to registries
- **Push image to registry** - Upload to GitHub Container Registry or other registries
- **Remove image** - Delete local images

### Configuration Management
- **Saved configurations** - Reuse container setups (image, volumes, ports, shell)
- **Dry-run mode** - Preview commands without executing them

## Configuration Files

Container configurations are saved in `~/.config/podman-wizard/` and can be:
- Loaded when creating new containers
- Viewed and deleted through the management menu

## Volume Mapping

The wizard offers convenient volume mapping presets:
- Home directory
- Current directory  
- Documents folder
- Custom `my_home` directory (relative to script location)
- Manual custom mapping

## Tips

- Use **dry-run mode** (option 'd' in the menu, or `--dry-run` on the command line) to see what commands will be executed
- Save frequently used container configurations for quick setup
- The script automatically detects running/stopped containers for easy selection

## Advanced Usage

For manual Podman commands and advanced configurations, see [MANUAL_COMMANDS.md](MANUAL_COMMANDS.md).

For a Debian development sandbox, see [sandbox/README.md](sandbox/README.md).
