#!/usr/bin/env bash

# Create and manage Podman development sandboxes.
set -Eeuo pipefail

DRY_RUN=false
CONFIG_DIR="${HOME}/.config/sandbox-wizard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGE="debian-dev-sandbox:latest"
DEFAULT_USER="dev"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

print_header() {
    printf '\n%b=== Podman Sandbox Wizard ===%b\n\n' "$BOLD$BLUE" "$NC"
}

print_command() {
    printf '%bCommand:%b' "$YELLOW" "$NC"
    printf ' %q' podman "$@"
    printf '\n'
}

run_podman() {
    print_command "$@"
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Command not executed%b\n' "$BLUE" "$NC"
        return 0
    fi
    podman "$@"
}

prompt_input() {
    local prompt="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        REPLY="${value:-$default}"
    else
        read -r -p "$prompt: " value
        REPLY="$value"
    fi
}

confirm() {
    local prompt="$1" default="${2:-n}" response
    if [[ "$default" == y ]]; then
        read -r -p "$prompt (Y/n): " response
        response="${response:-y}"
    else
        read -r -p "$prompt (y/N): " response
        response="${response:-n}"
    fi
    [[ "$response" =~ ^[Yy]$ ]]
}

valid_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

config_path() {
    valid_name "$1" || return 1
    printf '%s/%s.cfg' "$CONFIG_DIR" "$1"
}

save_sandbox_config() {
    local name="$1" file
    file="$(config_path "$name")"
    umask 077
    {
        printf '# Sandbox wizard configuration. Secret values are not stored here.\n'
        printf 'IMAGE=%q\n' "$IMAGE"
        printf 'CONTAINER_NAME=%q\n' "$CONTAINER_NAME"
        printf 'SANDBOX_USER=%q\n' "$SANDBOX_USER"
        printf 'GIT_NAME=%q\n' "$GIT_NAME"
        printf 'GIT_EMAIL=%q\n' "$GIT_EMAIL"
        printf 'HOME_HOST=%q\n' "$HOME_HOST"
        printf 'HOME_CONTAINER=%q\n' "$HOME_CONTAINER"
        printf 'SANDBOX_SHELL=%q\n' "$SANDBOX_SHELL"
        printf 'SSH_SECRET_NAME=%q\n' "$SSH_SECRET_NAME"
        declare -p API_SECRET_NAMES API_SECRET_VARS
    } > "$file"
    chmod 600 "$file"
    printf '%bSaved configuration:%b %s\n' "$GREEN" "$NC" "$file"
}

reset_sandbox_config() {
    IMAGE="$DEFAULT_IMAGE"
    CONTAINER_NAME=""
    SANDBOX_USER="$DEFAULT_USER"
    GIT_NAME=""
    GIT_EMAIL=""
    HOME_HOST=""
    HOME_CONTAINER=""
    SANDBOX_SHELL="/bin/bash"
    SSH_SECRET_NAME=""
    API_SECRET_NAMES=()
    API_SECRET_VARS=()
}

load_sandbox_config() {
    local name="$1" file
    file="$(config_path "$name")"
    [[ -f "$file" ]] || return 1
    reset_sandbox_config
    # Config files are private files created by this wizard in ~/.config.
    # shellcheck disable=SC1090
    source "$file"
    return 0
}

list_config_names() {
    local file
    shopt -s nullglob
    for file in "$CONFIG_DIR"/*.cfg; do
        basename "$file" .cfg
    done
    shopt -u nullglob
}

get_image_user() {
    local image="$1" user=""
    if [[ "$DRY_RUN" == false ]] && podman image exists "$image" 2>/dev/null; then
        user="$(podman image inspect --format '{{ index .Config.Labels "io.mypodman.sandbox-user" }}' "$image" 2>/dev/null || true)"
        [[ "$user" == '<no value>' || "$user" == '<nil>' ]] && user=""
    fi
    printf '%s' "$user"
}

build_image() {
    local image user
    prompt_input "Image tag" "$DEFAULT_IMAGE"
    image="$REPLY"
    prompt_input "Container user name" "$DEFAULT_USER"
    user="$REPLY"
    if ! [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        printf '%bInvalid user name. Use a letter or underscore first, then letters, digits, _ or -.%b\n' "$RED" "$NC" >&2
        return 1
    fi
    run_podman build --build-arg "USER_NAME=$user" -t "$image" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
}

prepare_secret() {
    local secret_name="$1" kind="$2" source="$3" value=""
    if ! valid_name "$secret_name"; then
        printf '%bInvalid secret name: %s%b\n' "$RED" "$secret_name" "$NC" >&2
        return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Secret existence and content are not checked.%b\n' "$BLUE" "$NC"
        return 0
    fi
    if podman secret inspect "$secret_name" >/dev/null 2>&1; then
        printf 'Using existing Podman secret %s.\n' "$secret_name"
        return 0
    fi

    if [[ "$kind" == api ]]; then
        read -r -s -p "Value for API secret $secret_name: " value
        printf '\n'
        if [[ -z "$value" ]]; then
            printf '%bThe secret value cannot be empty.%b\n' "$RED" "$NC" >&2
            return 1
        fi
        printf '%s' "$value" | run_podman secret create "$secret_name" - || return 1
        unset value
    else
        if [[ ! -f "$source" || ! -r "$source" ]]; then
            printf '%bCannot read SSH key file: %s%b\n' "$RED" "$source" "$NC" >&2
            return 1
        fi
        local mode
        if stat -f '%Lp' "$source" >/dev/null 2>&1; then
            mode="$(stat -f '%Lp' "$source")"
        else
            mode="$(stat -c '%a' "$source")"
        fi
        if (( (8#$mode & 077) != 0 )); then
            printf '%bWarning: %s is readable by group or other users (mode %s).%b\n' "$YELLOW" "$source" "$mode" "$NC" >&2
            confirm "Continue and copy this key into a Podman secret" || return 1
        fi
        cat "$source" | run_podman secret create "$secret_name" - || return 1
    fi
}

add_api_secret_from_environment() {
    local env_name="$1" secret_name value
    value="${!env_name}"
    if [[ -z "$value" ]]; then
        printf '%bSkipping %s because its value is empty.%b\n' "$YELLOW" "$env_name" "$NC"
        return 1
    fi

    secret_name="$env_name"
    if ! valid_name "$secret_name"; then
        secret_name="${CONTAINER_NAME}-${env_name}"
    fi

    if [[ "$DRY_RUN" == false ]] && podman secret inspect "$secret_name" >/dev/null 2>&1; then
        printf 'Podman secret %s already exists.\n' "$secret_name"
        if confirm "Reuse the stored secret instead of the current environment value" n; then
            API_SECRET_NAMES+=("$secret_name")
            API_SECRET_VARS+=("$env_name")
            unset value
            return 0
        fi
        prompt_input "New Podman secret name" "${CONTAINER_NAME}-${env_name}"
        secret_name="$REPLY"
        if ! valid_name "$secret_name"; then
            printf '%bInvalid Podman secret name: %s%b\n' "$RED" "$secret_name" "$NC" >&2
            unset value
            return 1
        fi
        if podman secret inspect "$secret_name" >/dev/null 2>&1; then
            printf '%bPodman secret %s already exists. Choose another name or remove it first.%b\n' "$RED" "$secret_name" "$NC" >&2
            unset value
            return 1
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Would create secret %s from environment variable %s. The value is hidden.%b\n' "$BLUE" "$secret_name" "$env_name" "$NC"
        run_podman secret create "$secret_name" - || { unset value; return 1; }
    else
        printf '%s' "$value" | run_podman secret create "$secret_name" - || { unset value; return 1; }
    fi
    API_SECRET_NAMES+=("$secret_name")
    API_SECRET_VARS+=("$env_name")
    unset value
}

add_api_secrets() {
    local env_name secret_name
    local -a env_vars=()
    while IFS= read -r env_name; do
        [[ -n "$env_name" ]] && env_vars+=("$env_name")
    done < <(compgen -e | grep -i 'API_KEY' || true)

    if ((${#env_vars[@]} > 0)); then
        printf 'Exported environment variable names containing API_KEY were found. Values will not be displayed.\n'
        for env_name in "${env_vars[@]}"; do
            if confirm "Provide $env_name to this sandbox as a Podman secret" n; then
                add_api_secret_from_environment "$env_name" || true
            fi
        done
    else
        printf 'No exported environment variable names containing API_KEY were found.\n'
    fi

    while confirm "Add another API key manually" n; do
        prompt_input "Podman secret name"
        secret_name="$REPLY"
        prompt_input "Environment variable name" "$(printf '%s' "$secret_name" | tr '[:lower:].-' '[:upper:]__')"
        env_name="$REPLY"
        if ! [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf '%bInvalid environment variable name: %s%b\n' "$RED" "$env_name" "$NC" >&2
            continue
        fi
        if prepare_secret "$secret_name" api ""; then
            API_SECRET_NAMES+=("$secret_name")
            API_SECRET_VARS+=("$env_name")
        fi
    done
}

add_ssh_secret() {
    local source secret_name ssh_dir
    SSH_SECRET_NAME=""
    if ! confirm "Mount an SSH private key" n; then
        return 0
    fi
    prompt_input "SSH private key path" "$HOME/.ssh/id_ed25519"
    source="$REPLY"
    source="${source/#\~/$HOME}"
    if [[ ! -f "$source" || ! -r "$source" ]]; then
        printf '%bCannot read SSH key file: %s%b\n' "$RED" "$source" "$NC" >&2
        return 1
    fi
    prompt_input "Podman secret name" "${CONTAINER_NAME}-ssh-key"
    secret_name="$REPLY"
    if ! prepare_secret "$secret_name" ssh "$source"; then
        return 1
    fi
    ssh_dir="$HOME_HOST/.ssh"
    if [[ -L "$ssh_dir" ]]; then
        printf '%bRefusing to use a symlink as the mounted .ssh directory: %s%b\n' "$RED" "$ssh_dir" "$NC" >&2
        return 1
    fi
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    SSH_SECRET_NAME="$secret_name"
}

initialize_sandbox() {
    local name="$1" git_name="${2:-}" git_email="${3:-}" shell_payload
    shell_payload='set -eu
if [ -n "$SANDBOX_GIT_NAME" ]; then
  git config --global user.name "$SANDBOX_GIT_NAME"
  jj config set --user user.name "$SANDBOX_GIT_NAME"
fi
if [ -n "$SANDBOX_GIT_EMAIL" ]; then
  git config --global user.email "$SANDBOX_GIT_EMAIL"
  jj config set --user user.email "$SANDBOX_GIT_EMAIL"
fi
if [ -d "$HOME/.ssh" ]; then
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$HOME/.ssh/config" ]; then
    printf "Host *\\n  StrictHostKeyChecking accept-new\\n" > "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
fi'
    run_podman exec \
        -e "SANDBOX_GIT_NAME=$git_name" \
        -e "SANDBOX_GIT_EMAIL=$git_email" \
        "$name" /bin/bash -lc "$shell_payload"
}

create_sandbox() {
    local image_user cwd selinux_suffix mount_spec existing
    reset_sandbox_config
    cwd="$(pwd -P)"
    HOME_HOST="$cwd"

    prompt_input "Sandbox container name" "dev-sandbox"
    CONTAINER_NAME="$REPLY"
    if ! valid_name "$CONTAINER_NAME"; then
        printf '%bInvalid container name: %s%b\n' "$RED" "$CONTAINER_NAME" "$NC" >&2
        return 1
    fi
    prompt_input "Image tag" "$DEFAULT_IMAGE"
    IMAGE="$REPLY"
    image_user="$(get_image_user "$IMAGE")"
    SANDBOX_USER="${image_user:-$DEFAULT_USER}"
    prompt_input "Container user name (must match the image)" "$SANDBOX_USER"
    SANDBOX_USER="$REPLY"
    if ! [[ "$SANDBOX_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        printf '%bInvalid user name.%b\n' "$RED" "$NC" >&2
        return 1
    fi
    if [[ -n "$image_user" && "$SANDBOX_USER" != "$image_user" ]]; then
        printf '%bThis image was built for user %s. Rebuild it to use another name.%b\n' "$RED" "$image_user" "$NC" >&2
        return 1
    fi
    prompt_input "Shell" "/bin/bash"
    SANDBOX_SHELL="$REPLY"
    HOME_CONTAINER="/home/$SANDBOX_USER"

    if [[ "$cwd" == "$(cd "$HOME" && pwd -P)" ]]; then
        printf '%bWarning: this mounts your host home directory over the container home.%b\n' "$YELLOW" "$NC" >&2
        confirm "Continue" || return 1
    fi

    local host_name host_email
    host_name="$(git config --global user.name 2>/dev/null || true)"
    host_email="$(git config --global user.email 2>/dev/null || true)"
    prompt_input "Git and jj user name" "$host_name"
    GIT_NAME="$REPLY"
    prompt_input "Git and jj email" "$host_email"
    GIT_EMAIL="$REPLY"

    add_api_secrets
    add_ssh_secret

    selinux_suffix=""
    if [[ "$(uname -s)" == Linux ]]; then
        selinux_suffix=",Z"
    fi
    mount_spec="$HOME_HOST:$HOME_CONTAINER:rw$selinux_suffix"

    local -a args=(run -d -it --name "$CONTAINER_NAME"
        --label io.mypodman.sandbox=true
        --userns=keep-id:uid=1000,gid=1000
        --user 1000:1000
        --volume "$mount_spec"
        --workdir "$HOME_CONTAINER")
    local i
    for i in "${!API_SECRET_NAMES[@]}"; do
        args+=(--secret "${API_SECRET_NAMES[$i]},type=env,target=${API_SECRET_VARS[$i]}")
    done
    if [[ -n "$SSH_SECRET_NAME" ]]; then
        args+=(--secret "$SSH_SECRET_NAME,target=$HOME_CONTAINER/.ssh/id_ed25519,uid=1000,gid=1000,mode=0400")
    fi
    args+=("$IMAGE" sleep infinity)
    run_podman "${args[@]}"

    if [[ "$DRY_RUN" == false ]]; then
        initialize_sandbox "$CONTAINER_NAME" "$GIT_NAME" "$GIT_EMAIL"
    fi
    if confirm "Save this sandbox configuration" y; then
        save_sandbox_config "$CONTAINER_NAME"
    fi
}

select_running_container() {
    local -a names=()
    local name choice index=1
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Enter a container name manually.%b\n' "$BLUE" "$NC"
        prompt_input "Container name"
        return 0
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(podman ps --filter label=io.mypodman.sandbox=true --format '{{.Names}}')
    if ((${#names[@]} == 0)); then
        printf 'No running sandbox containers found.\n'
        return 1
    fi
    for name in "${names[@]}"; do
        printf '  %d) %s\n' "$index" "$name"
        ((index += 1))
    done
    read -r -p 'Select a container: ' choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#names[@]})); then
        REPLY="${names[$((choice - 1))]}"
        return 0
    fi
    return 1
}

enter_sandbox() {
    local name="${1:-}" shell="${2:-}"
    if [[ -z "$name" ]]; then
        select_running_container || return 1
        name="$REPLY"
    fi
    if load_sandbox_config "$name"; then
        shell="${shell:-$SANDBOX_SHELL}"
        initialize_sandbox "$name" "$GIT_NAME" "$GIT_EMAIL"
    else
        shell="${shell:-/bin/bash}"
        initialize_sandbox "$name" "" ""
    fi
    run_podman exec -it "$name" "$shell"
}

list_sandboxes() {
    local -a args=(ps --filter label=io.mypodman.sandbox=true)
    if [[ "${1:-}" == all ]]; then
        args=(ps -a --filter label=io.mypodman.sandbox=true)
    fi
    run_podman "${args[@]}"
}

manage_secrets() {
    local action="${1:-ls}" name value
    case "$action" in
        ls|list)
            printf 'Podman secrets stored on this Podman connection. This list does not show container mappings.\n'
            run_podman secret ls
            ;;
        create)
            name="${2:-}"
            if [[ -z "$name" ]]; then
                prompt_input "Podman secret name"
                name="$REPLY"
            fi
            if ! valid_name "$name"; then
                printf '%bInvalid secret name.%b\n' "$RED" "$NC" >&2
                return 1
            fi
            if [[ "$DRY_RUN" == false ]] && podman secret inspect "$name" >/dev/null 2>&1; then
                printf 'Secret already exists: %s\n' "$name" >&2
                return 1
            fi
            if [[ "$DRY_RUN" == true ]]; then
                run_podman secret create "$name" -
            else
                read -r -s -p "Value for secret $name: " value
                printf '\n'
                [[ -n "$value" ]] || { printf 'Secret value cannot be empty.\n' >&2; return 1; }
                printf '%s' "$value" | run_podman secret create "$name" -
                unset value
            fi
            ;;
        rm|remove)
            name="${2:-}"
            if [[ -z "$name" ]]; then
                prompt_input "Podman secret name"
                name="$REPLY"
            fi
            run_podman secret rm "$name"
            ;;
        *)
            printf 'Usage: %s secrets {ls|create [name]|rm [name]}\n' "$0"
            ;;
    esac
}

manage_configs() {
    local action="${1:-ls}" name file
    case "$action" in
        ls|list)
            local found=false
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                printf '%s\n' "$name"
                found=true
            done < <(list_config_names)
            [[ "$found" == true ]] || printf 'No saved sandbox configurations.\n'
            ;;
        rm|remove)
            name="${2:-}"
            if [[ -z "$name" ]]; then
                prompt_input "Sandbox configuration name"
                name="$REPLY"
            fi
            file="$(config_path "$name")"
            if [[ -f "$file" ]]; then
                rm -- "$file"
                printf 'Removed %s\n' "$file"
            else
                printf 'No saved configuration for %s\n' "$name" >&2
                return 1
            fi
            ;;
        *)
            printf 'Usage: %s configs {ls|rm [name]}\n' "$0"
            ;;
    esac
}

run_cli() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        help|-h|--help)
            cat <<EOF
Usage:
  $0                         Open the interactive menu
  $0 help                    Show this help
  $0 [--dry-run|-n] COMMAND [ARGS...]

Commands:
  build                      Build the Debian development image
  create                     Create a sandbox from the current directory
  enter [NAME] [SHELL]       Enter a running sandbox
  ps [all]                   List running sandboxes, or all sandboxes
  start NAME                 Start a stopped sandbox
  stop NAME                  Stop a sandbox
  rm NAME                    Remove a sandbox
  commit NAME IMAGE          Save a sandbox as a new image
  secrets [ls|create|rm]     List, create, or remove Podman secrets
  configs [ls|rm]            List or remove saved sandbox configurations

Create flow:
  The wizard asks which exported environment variables containing API_KEY to pass as secrets.
  It displays variable names only. It asks separately whether to mount an SSH private key.
  The current directory becomes /home/<user> inside the sandbox.

Secrets:
  secrets ls lists secrets stored by Podman. It does not show container mappings.
  API secrets enter the sandbox as environment variables. SSH keys use a read-only secret file.

Examples:
  $0 build
  $0 create
  $0 enter dev-sandbox
  $0 --dry-run create
  $0 secrets ls
EOF
            ;;
        build)
            build_image
            ;;
        create)
            create_sandbox
            ;;
        enter|exec)
            enter_sandbox "${1:-}" "${2:-/bin/bash}"
            ;;
        ps)
            list_sandboxes "${1:-}"
            ;;
        start|stop|rm)
            if [[ -z "${1:-}" ]]; then
                printf 'Usage: %s %s NAME\n' "$0" "$command" >&2
                return 1
            fi
            run_podman "$command" "$1"
            ;;
        commit)
            if [[ -z "${1:-}" || -z "${2:-}" ]]; then
                printf 'Usage: %s commit NAME IMAGE\n' "$0" >&2
                return 1
            fi
            run_podman commit "$1" "$2"
            ;;
        secrets)
            manage_secrets "${1:-}" "${2:-}"
            ;;
        configs)
            manage_configs "${1:-ls}" "${2:-}"
            ;;
        *)
            printf 'Unknown command: %s\n' "$command" >&2
            run_cli help >&2
            return 1
            ;;
    esac
}

main() {
    local choice
    while true; do
        print_header
        [[ "$DRY_RUN" == true ]] && printf '%b[DRY-RUN MODE ACTIVE]%b\n\n' "$YELLOW" "$NC"
        cat <<'EOF'
Sandbox operations:
  1) Build the development image
  2) Create a sandbox
  3) Enter a running sandbox
  4) List running sandboxes
  5) List all sandboxes
  6) Start a sandbox
  7) Stop a sandbox
  8) Remove a sandbox
  9) Commit a sandbox as an image
  s) Manage Podman secrets
  c) Manage saved configurations
  d) Toggle dry-run mode
  q) Quit
EOF
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) build_image ;;
            2) create_sandbox ;;
            3) enter_sandbox ;;
            4) list_sandboxes ;;
            5) list_sandboxes all ;;
            6|7|8)
                prompt_input 'Sandbox container name'
                case "$choice" in
                    6) run_podman start "$REPLY" ;;
                    7) run_podman stop "$REPLY" ;;
                    8) run_podman rm "$REPLY" ;;
                esac
                ;;
            9)
                prompt_input 'Sandbox container name'
                local container="$REPLY"
                prompt_input 'New image tag'
                run_podman commit "$container" "$REPLY"
                ;;
            s|S) manage_secrets ;;
            c|C) manage_configs ;;
            d|D) [[ "$DRY_RUN" == true ]] && DRY_RUN=false || DRY_RUN=true ;;
            q|Q) return 0 ;;
            *) printf 'Choose one of the listed options.\n' ;;
        esac
        printf '\n'
        read -r -p 'Press Enter to continue...' _
    done
}

if [[ "${1:-}" == -n || "${1:-}" == --dry-run ]]; then
    DRY_RUN=true
    shift
fi

if [[ "$DRY_RUN" == false ]] && ! command -v podman >/dev/null 2>&1; then
    printf '%bError: podman was not found. Install Podman first.%b\n' "$RED" "$NC" >&2
    exit 1
fi

if (($# > 0)); then
    run_cli "$@"
else
    main
fi
