#!/bin/bash

# Podman Operations Wizard
# Interactive menu-driven script for common podman operations

set -e

DRY_RUN=false
CONFIG_DIR="${HOME}/.config/podman-wizard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

print_header() {
    echo -e "\n${BOLD}${BLUE}=== Podman Operations Wizard ===${NC}\n"
}

print_command() {
    echo -e "${YELLOW}Command:${NC} ${GREEN}$1${NC}"
}

execute_or_display() {
    local cmd="$1"
    print_command "$cmd"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Command not executed${NC}"
    else
        echo -e "${BLUE}Executing...${NC}"
        eval "$cmd"
    fi
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local result
    
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -p "$prompt: " result
        echo "$result"
    fi
}

confirm() {
    local prompt="$1"
    local response
    read -p "$prompt (y/n): " response
    [[ "$response" =~ ^[Yy]$ ]]
}

list_containers() {
    local flag="$1"
    echo -e "\n${BOLD}Listing containers...${NC}"
    if [ "$flag" = "-a" ]; then
        execute_or_display "podman ps -a"
    else
        execute_or_display "podman ps"
    fi
}

list_images() {
    echo -e "\n${BOLD}Listing images...${NC}"
    execute_or_display "podman images"
}

save_container_config() {
    local name="$1"
    local image="$2"
    local volume="$3"
    local ports="$4"
    local shell="$5"
    local userns="$6"
    
    local config_file="$CONFIG_DIR/${name}.cfg"
    cat > "$config_file" <<EOF
# Podman container configuration for: $name
# Created: $(date)
IMAGE="$image"
VOLUME="$volume"
PORTS="$ports"
SHELL="$shell"
USERNS="$userns"
EOF
    echo -e "${GREEN}Configuration saved to: $config_file${NC}"
}

load_container_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        source "$config_file"
        return 0
    fi
    return 1
}

list_saved_configs() {
    local configs=($(ls "$CONFIG_DIR"/*.cfg 2>/dev/null | xargs -n 1 basename 2>/dev/null || true))
    echo "${configs[@]}"
}

select_config() {
    local configs=($(list_saved_configs))
    
    if [ ${#configs[@]} -eq 0 ]; then
        return 1
    fi
    
    echo -e "\n${BOLD}Saved configurations:${NC}"
    local i=1
    for cfg in "${configs[@]}"; do
        local name="${cfg%.cfg}"
        echo "  $i) $name"
        ((i++))
    done
    echo "  0) Create new configuration"
    echo ""
    
    local choice
    read -p "Select config (0-${#configs[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#configs[@]} ]; then
        local config_file="$CONFIG_DIR/${configs[$((choice-1))]}"
        if load_container_config "$config_file"; then
            echo -e "${GREEN}Loaded configuration: ${configs[$((choice-1))]}${NC}"
            return 0
        fi
    fi
    return 1
}

enter_container() {
    echo -e "\n${BOLD}Enter/exec into container${NC}"
    
    # Get list of running containers
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would list running containers with: podman ps --format '{{.Names}}'${NC}"
        local containers=()
    else
        local containers=($(podman ps --format '{{.Names}}' 2>/dev/null || true))
    fi
    
    if [ ${#containers[@]} -eq 0 ]; then
        echo "No running containers found."
        return
    fi
    
    echo ""
    local i=1
    for container in "${containers[@]}"; do
        echo "  $i) $container"
        ((i++))
    done
    echo "  0) Enter container name manually"
    echo ""
    
    local choice
    read -p "Select container to enter (0-${#containers[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#containers[@]} ]; then
        local container="${containers[$((choice-1))]}"
        echo -e "${GREEN}Selected: $container${NC}"
    else
        local container=$(prompt_input "Enter container name")
        if [ -z "$container" ]; then
            echo "Cancelled"
            return
        fi
    fi
    
    local shell=$(prompt_input "Enter shell" "/bin/bash")
    execute_or_display "podman exec -it $container $shell"
}

create_container() {
    echo -e "\n${BOLD}Create and run a new container${NC}"
    
    # Try to load existing config
    local IMAGE="" VOLUME="" PORTS="" SHELL="/bin/bash" USERNS="--userns=keep-id"
    local config_loaded=false
    
    if select_config; then
        config_loaded=true
        echo -e "${BLUE}Using saved configuration as defaults${NC}"
    fi
    
    local name=$(prompt_input "Container name")
    
    # Show existing images and let user choose
    echo -e "\n${BOLD}Available local images:${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would list images with: podman images --format '{{.Repository}}:{{.Tag}}'${NC}"
        local images=()
    else
        local images=($(podman images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>:<none>' || true))
    fi
    
    local image=""
    if [ ${#images[@]} -gt 0 ]; then
        local i=1
        for img in "${images[@]}"; do
            echo "  $i) $img"
            ((i++))
        done
        echo "  0) Enter remote image name"
        if [ -n "$IMAGE" ]; then
            echo -e "  ${YELLOW}Default from config: $IMAGE${NC}"
        fi
        echo ""
        
        local choice
        read -p "Select image (0-$((${#images[@]})), or press Enter for default): " choice
        
        if [ -z "$choice" ] && [ -n "$IMAGE" ]; then
            image="$IMAGE"
            echo -e "${GREEN}Using default: $image${NC}"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#images[@]} ]; then
            image="${images[$((choice-1))]}"
            echo -e "${GREEN}Selected: $image${NC}"
        else
            image=$(prompt_input "Enter remote image name" "$IMAGE")
        fi
    else
        echo "  (No local images found)"
        image=$(prompt_input "Enter remote image name" "$IMAGE")
    fi
    
    # Show volume mapping options
    echo -e "\n${BOLD}Volume mapping:${NC}"
    echo "  1) Map home directory: $HOME:$HOME"
    echo "  2) Map current directory: $(pwd):$(pwd)"
    if [ -d "$HOME/Documents" ]; then
        echo "  3) Map Documents: $HOME/Documents:$HOME/Documents"
    fi
    local my_home_dir="$SCRIPT_DIR/my_home"
    if [ -d "$my_home_dir" ]; then
        echo "  4) Map my_home directory (will prompt for container path)"
    fi
    echo "  5) Custom volume mapping"
    echo "  0) No volume mapping"
    if [ -n "$VOLUME" ]; then
        echo -e "  ${YELLOW}Default from config: $VOLUME${NC}"
    fi
    echo ""
    
    local vol_choice
    read -p "Select volume option (0-5, or press Enter for default): " vol_choice
    
    if [ -z "$vol_choice" ] && [ -n "$VOLUME" ]; then
        local volume="$VOLUME"
        echo -e "${GREEN}Using default: $volume${NC}"
        vol_choice="skip"
    fi
    
    case $vol_choice in
        skip)
            # Already set from default
            ;;
        1)
            local volume="$HOME:$HOME"
            echo -e "${GREEN}Selected: $volume${NC}"
            ;;
        2)
            local volume="$(pwd):$(pwd)"
            echo -e "${GREEN}Selected: $volume${NC}"
            ;;
        3)
            if [ -d "$HOME/Documents" ]; then
                local volume="$HOME/Documents:$HOME/Documents"
                echo -e "${GREEN}Selected: $volume${NC}"
            else
                local volume=$(prompt_input "Enter volume mapping (host:container)" "$VOLUME")
            fi
            ;;
        4)
            if [ -d "$my_home_dir" ]; then
                local container_path=$(prompt_input "Enter container mount path (e.g., /home/username)" "/home/$(whoami)")
                local volume="$my_home_dir:$container_path"
                echo -e "${GREEN}Selected: $volume${NC}"
            else
                local volume=$(prompt_input "Enter volume mapping (host:container)" "$VOLUME")
            fi
            ;;
        5)
            local volume=$(prompt_input "Enter volume mapping (host:container)" "$VOLUME")
            ;;
        0)
            local volume=""
            echo -e "${GREEN}No volume mapping${NC}"
            ;;
        *)
            echo -e "${YELLOW}Invalid choice, skipping volume mapping${NC}"
            local volume=""
            ;;
    esac
    
    local shell=$(prompt_input "Shell" "${SHELL:-/bin/bash}")
    
    # Ask user about UID/GID mapping strategy
    echo -e "\n${BOLD}User namespace mapping:${NC}"
    echo "  1) Auto-map to your host UID (keep-id) - Recommended"
    echo "  2) Map to specific container UID (e.g., 1000:1000)"
    echo "  3) No user namespace (run as image default user)"
    echo ""
    
    local userns_choice
    read -p "Select option (1-3) [1]: " userns_choice
    userns_choice=${userns_choice:-1}
    
    local userns_flags=""
    case $userns_choice in
        1)
            # Keep host UID/GID - override image USER and remap namespace
            userns_flags="--userns=keep-id --user $(id -u):$(id -g)"
            echo -e "${GREEN}Using: Auto-map to host UID $(id -u):$(id -g)${NC}"
            ;;
        2)
            local target_uid=$(prompt_input "Target container UID" "1000")
            local target_gid=$(prompt_input "Target container GID" "1000")
            userns_flags="--userns=keep-id:uid=${target_uid},gid=${target_gid} --user ${target_uid}:${target_gid}"
            echo -e "${GREEN}Using: Map to container UID ${target_uid}:${target_gid}${NC}"
            ;;
        3)
            userns_flags=""
            echo -e "${YELLOW}No user namespace mapping - running as image default user${NC}"
            ;;
        *)
            userns_flags="--userns=keep-id --user $(id -u):$(id -g)"
            echo -e "${GREEN}Using: Auto-map to host UID $(id -u):$(id -g) (default)${NC}"
            ;;
    esac
    
    local cmd="podman run --name=$name"
    
    if [ -n "$userns_flags" ]; then
        cmd="$cmd $userns_flags"
    fi
    
    if [ -n "$volume" ]; then
        cmd="$cmd -v $volume"
    fi
    
    echo ""
    local ports=""
    local should_map_ports=true
    
    if [ -n "$PORTS" ]; then
        echo -e "${YELLOW}Default ports from config: $PORTS${NC}"
        if confirm "Use default ports?"; then
            ports="$PORTS"
            should_map_ports=false
            for port in ${ports//,/ }; do
                cmd="$cmd -p $port"
            done
            echo -e "${GREEN}Using default port mappings${NC}"
        fi
    fi
    
    if [ "$should_map_ports" = true ] && confirm "Map ports?"; then
        echo -e "${BOLD}Port mapping:${NC} (format: host:container, e.g., 9080:8080)"
        local port_count=0
        local port_list=()
        while true; do
            local port=$(prompt_input "Port mapping $((port_count + 1)) (empty to finish)")
            if [ -z "$port" ]; then
                break
            fi
            cmd="$cmd -p $port"
            port_list+=("$port")
            ((port_count++))
            echo -e "${GREEN}Added port mapping: $port${NC}"
        done
        if [ $port_count -eq 0 ]; then
            echo -e "${YELLOW}No ports mapped${NC}"
            ports=""
        else
            echo -e "${GREEN}Total ports mapped: $port_count${NC}"
            ports=$(IFS=,; echo "${port_list[*]}")
        fi
    fi
    
    # Ask about working directory
    echo ""
    if confirm "Set working directory to mounted volume?"; then
        if [ -n "$volume" ]; then
            # Extract container path from volume mapping (format: host:container)
            local container_path="${volume#*:}"
            cmd="$cmd -w $container_path"
            echo -e "${GREEN}Working directory: $container_path${NC}"
        else
            echo -e "${YELLOW}No volume mounted, skipping working directory${NC}"
        fi
    fi
    
    cmd="$cmd -it $image $shell"
    execute_or_display "$cmd"
    
    # Offer to save configuration
    if [ "$DRY_RUN" = false ]; then
        echo ""
        if confirm "Save this configuration for future use?"; then
            save_container_config "$name" "$image" "$volume" "$ports" "$shell" "$userns_flags"
        fi
    fi
}

start_container() {
    echo -e "\n${BOLD}Start a stopped container${NC}"
    
    # Get list of stopped containers
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would list stopped containers with: podman ps -a --filter 'status=exited' --format '{{.Names}}'${NC}"
        local containers=()
    else
        local containers=($(podman ps -a --filter 'status=exited' --format '{{.Names}}' 2>/dev/null || true))
    fi
    
    if [ ${#containers[@]} -eq 0 ]; then
        echo "No stopped containers found."
        return
    fi
    
    echo ""
    local i=1
    for container in "${containers[@]}"; do
        echo "  $i) $container"
        ((i++))
    done
    echo "  0) Enter container name manually"
    echo ""
    
    local choice
    read -p "Select container to start (0-${#containers[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#containers[@]} ]; then
        local container="${containers[$((choice-1))]}"
        echo -e "${GREEN}Selected: $container${NC}"
    else
        local container=$(prompt_input "Enter container name to start")
    fi
    
    execute_or_display "podman start $container"
}

stop_container() {
    echo -e "\n${BOLD}Stop a running container${NC}"
    
    # Get list of running containers
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would list running containers with: podman ps --format '{{.Names}}'${NC}"
        local containers=()
    else
        local containers=($(podman ps --format '{{.Names}}' 2>/dev/null || true))
    fi
    
    if [ ${#containers[@]} -eq 0 ]; then
        echo "No running containers found."
        return
    fi
    
    echo ""
    local i=1
    for container in "${containers[@]}"; do
        echo "  $i) $container"
        ((i++))
    done
    echo "  0) Enter container name manually"
    echo ""
    
    local choice
    read -p "Select container to stop (0-${#containers[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#containers[@]} ]; then
        local container="${containers[$((choice-1))]}"
        echo -e "${GREEN}Selected: $container${NC}"
    else
        local container=$(prompt_input "Enter container name to stop")
    fi
    
    execute_or_display "podman stop $container"
}

remove_container() {
    echo -e "\n${BOLD}Remove a container${NC}"
    
    # Get list of all containers (prioritize stopped ones)
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would list all containers with: podman ps -a --format '{{.Names}}\t{{.Status}}'${NC}"
        local containers=()
    else
        local containers=($(podman ps -a --format '{{.Names}}' 2>/dev/null || true))
    fi
    
    if [ ${#containers[@]} -eq 0 ]; then
        echo "No containers found."
        return
    fi
    
    echo ""
    local i=1
    for container in "${containers[@]}"; do
        # Show container status
        if [ "$DRY_RUN" = false ]; then
            local status=$(podman ps -a --filter "name=^${container}$" --format '{{.Status}}' 2>/dev/null | head -1)
            echo "  $i) $container [$status]"
        else
            echo "  $i) $container"
        fi
        ((i++))
    done
    echo "  0) Enter container name manually"
    echo ""
    
    local choice
    read -p "Select container to remove (0-${#containers[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#containers[@]} ]; then
        local container="${containers[$((choice-1))]}"
        echo -e "${GREEN}Selected: $container${NC}"
    else
        local container=$(prompt_input "Enter container name to remove")
        if [ -z "$container" ]; then
            echo "Cancelled"
            return
        fi
    fi
    
    if confirm "Are you sure you want to remove container '$container'?"; then
        execute_or_display "podman rm $container"
    else
        echo "Cancelled"
    fi
}

commit_image() {
    echo -e "\n${BOLD}Save container as new image${NC}"
    list_containers -a
    echo ""
    local container=$(prompt_input "Enter container name")
    local image=$(prompt_input "New image name (e.g., registry.example.com/image:tag)")
    execute_or_display "podman commit $container $image"
}

remove_image() {
    list_images
    echo ""
    local image=$(prompt_input "Enter image name or ID to remove")
    if confirm "Are you sure you want to remove image '$image'?"; then
        execute_or_display "podman rmi $image"
    else
        echo "Cancelled"
    fi
}

tag_image() {
    list_images
    echo ""
    local source=$(prompt_input "Enter source image (name or ID)")
    local target=$(prompt_input "Enter target tag (e.g., ghcr.io/username/image:tag)")
    execute_or_display "podman tag $source $target"
}

push_image() {
    echo -e "\n${BOLD}Push image to registry${NC}"
    list_images
    echo ""
    
    if confirm "Do you need to login to a registry first?"; then
        local registry=$(prompt_input "Registry URL" "ghcr.io")
        local username=$(prompt_input "Username")
        echo "Note: You can set your token in an environment variable and use:"
        echo "  echo \$TOKEN | podman login $registry -u $username --password-stdin"
        if confirm "Login now (you'll be prompted for password)?"; then
            execute_or_display "podman login $registry -u $username"
        fi
    fi
    
    local image=$(prompt_input "Enter image name to push (e.g., ghcr.io/username/image:tag)")
    execute_or_display "podman push $image"
}

manage_configs() {
    echo -e "\n${BOLD}Manage Saved Configurations${NC}"
    
    local configs=($(list_saved_configs))
    
    if [ ${#configs[@]} -eq 0 ]; then
        echo "No saved configurations found."
        return
    fi
    
    echo ""
    local i=1
    for cfg in "${configs[@]}"; do
        local name="${cfg%.cfg}"
        echo "  $i) $name"
        ((i++))
    done
    echo ""
    
    local choice
    read -p "Select config to view/delete (0 to cancel): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#configs[@]} ]; then
        local config_file="$CONFIG_DIR/${configs[$((choice-1))]}"
        local config_name="${configs[$((choice-1))]%.cfg}"
        
        echo -e "\n${BOLD}Configuration: $config_name${NC}"
        cat "$config_file"
        echo ""
        
        if confirm "Delete this configuration?"; then
            rm "$config_file"
            echo -e "${GREEN}Configuration deleted${NC}"
        fi
    fi
}

toggle_dry_run() {
    if [ "$DRY_RUN" = true ]; then
        DRY_RUN=false
        echo -e "${GREEN}Dry-run mode: OFF${NC} - Commands will be executed"
    else
        DRY_RUN=true
        echo -e "${YELLOW}Dry-run mode: ON${NC} - Commands will only be displayed"
    fi
}

show_menu() {
    print_header
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN MODE ACTIVE]${NC}\n"
    fi
    
    echo "Container Operations:"
    echo "  1) List containers (running)"
    echo "  2) List all containers (including stopped)"
    echo "  3) Create and run new container"
    echo "  4) Enter/exec into container"
    echo "  5) Start stopped container"
    echo "  6) Stop running container"
    echo "  7) Remove container"
    echo ""
    echo "Image Operations:"
    echo "  8) List images"
    echo "  9) Save container as new image (commit)"
    echo " 10) Tag image"
    echo " 11) Push image to registry"
    echo " 12) Remove image"
    echo ""
    echo "Settings:"
    echo "  c) Manage saved configurations"
    echo "  d) Toggle dry-run mode (currently: $([ "$DRY_RUN" = true ] && echo "ON" || echo "OFF"))"
    echo "  q) Quit"
    echo ""
}

main() {
    while true; do
        show_menu
        read -p "Select an option: " choice
        
        case $choice in
            1)
                list_containers
                ;;
            2)
                list_containers -a
                ;;
            3)
                create_container
                ;;
            4)
                enter_container
                ;;
            5)
                start_container
                ;;
            6)
                stop_container
                ;;
            7)
                remove_container
                ;;
            8)
                list_images
                ;;
            9)
                commit_image
                ;;
            10)
                tag_image
                ;;
            11)
                push_image
                ;;
            12)
                remove_image
                ;;
            c|C)
                manage_configs
                ;;
            d|D)
                toggle_dry_run
                ;;
            q|Q)
                echo -e "\n${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Check if podman is available
if ! command -v podman &> /dev/null; then
    echo -e "${RED}Error: podman command not found. Please install podman first.${NC}"
    exit 1
fi

main
