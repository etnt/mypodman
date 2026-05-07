# Podman Operations Wizard

An interactive, menu-driven script for managing Podman containers and images.

## Quick Start

Run the wizard:

```bash
./podman-wizard.sh
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

- Use **dry-run mode** (option 'd') to see what commands will be executed
- Save frequently used container configurations for quick setup
- The script automatically detects running/stopped containers for easy selection

## Advanced Usage

For manual Podman commands and advanced configurations, see [MANUAL_COMMANDS.md](MANUAL_COMMANDS.md)
