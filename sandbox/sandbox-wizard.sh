#!/usr/bin/env bash

# Create and manage Podman development sandboxes.
set -Eeuo pipefail

DRY_RUN=false
CONFIG_DIR="${HOME}/.config/sandbox-wizard"
SOURCE_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE_PATH" ]]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" >/dev/null 2>&1 && pwd)"
    LINK_TARGET="$(readlink "$SOURCE_PATH")"
    if [[ "$LINK_TARGET" == /* ]]; then
        SOURCE_PATH="$LINK_TARGET"
    else
        SOURCE_PATH="$SOURCE_DIR/$LINK_TARGET"
    fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" >/dev/null 2>&1 && pwd)"
DEFAULT_IMAGE="debian-dev-sandbox:latest"
DEFAULT_PROXY_IMAGE="sandbox-credential-proxy:latest"
DEFAULT_USER="dev"
# The sandbox loopback bridge listens on this port. Proxy traffic uses it.
PROXY_PORT=8765
PROXY_SOCKET_DIR=/run/credential-proxy
PROXY_SOCKET_PATH=/run/credential-proxy/proxy.sock
PROXY_TOKEN_TARGET=/run/secrets/sandbox-proxy-token
BRIDGE_PATH=/usr/local/lib/sandbox/proxy_bridge.py
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
    local arg
    printf '%bCommand:%b' "$YELLOW" "$NC"
    printf ' %q' podman
    for arg in "$@"; do
        case "$arg" in
            OPENAI_API_KEY=*|OPENROUTER_API_KEY=*)
                arg="${arg%%=*}=<hidden>"
                ;;
        esac
        printf ' %q' "$arg"
    done
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
        printf 'WORKSPACE_MODE=%q\n' "$WORKSPACE_MODE"
        printf 'PROXY_CONTAINER_NAME=%q\n' "$PROXY_CONTAINER_NAME"
        printf 'PROXY_VOLUME_NAME=%q\n' "$PROXY_VOLUME_NAME"
        printf 'PROXY_TOKEN_SECRET=%q\n' "$PROXY_TOKEN_SECRET"
        printf 'PROXY_PORT=%q\n' "$PROXY_PORT"
        printf 'PROXY_PROVIDER_LIST=%q\n' "${PROXY_PROVIDERS[*]:-}"
        printf 'PROXY_SECRET_LIST=%q\n' "${PROXY_SECRET_NAMES[*]:-}"
        printf 'HOME_HOST=%q\n' "$HOME_HOST"
        printf 'HOME_CONTAINER=%q\n' "$HOME_CONTAINER"
        printf 'SANDBOX_SHELL=%q\n' "$SANDBOX_SHELL"
        printf 'SSH_SECRET_NAME=%q\n' "$SSH_SECRET_NAME"
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
    WORKSPACE_MODE="map"
    PROXY_CONTAINER_NAME=""
    PROXY_VOLUME_NAME=""
    PROXY_TOKEN_SECRET=""
    PROXY_PORT=8765
    PROXY_PROVIDER_LIST=""
    PROXY_SECRET_LIST=""
    PROXY_PROVIDERS=()
    PROXY_SECRET_NAMES=()
    HOME_HOST=""
    HOME_CONTAINER=""
    SANDBOX_SHELL="/bin/bash"
    SSH_SECRET_NAME=""
}

load_sandbox_config() {
    local name="$1" file
    file="$(config_path "$name")"
    [[ -f "$file" ]] || return 1
    reset_sandbox_config
    # Config files are private files created by this wizard in ~/.config.
    # shellcheck disable=SC1090
    source "$file"
    read -r -a PROXY_PROVIDERS <<< "${PROXY_PROVIDER_LIST:-}"
    read -r -a PROXY_SECRET_NAMES <<< "${PROXY_SECRET_LIST:-}"
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
    run_podman build -t "$DEFAULT_PROXY_IMAGE" -f "$SCRIPT_DIR/credential-proxy/Containerfile" "$SCRIPT_DIR/credential-proxy"
}

prepare_secret() {
    local secret_name="$1" source="$2" mode
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
    if [[ ! -f "$source" || ! -r "$source" ]]; then
        printf '%bCannot read SSH key file: %s%b\n' "$RED" "$source" "$NC" >&2
        return 1
    fi
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
}

random_secret_name() {
    # Print a secret name that does not exist yet.
    local base="$1" candidate
    candidate="${base}-${RANDOM}${RANDOM}"
    if [[ "$DRY_RUN" == false ]]; then
        while podman secret inspect "$candidate" >/dev/null 2>&1; do
            candidate="${base}-${RANDOM}${RANDOM}"
        done
    fi
    printf '%s' "$candidate"
}

add_api_secret_to_proxy() {
    local env_name="$1" provider value secret_name
    case "$env_name" in
        OPENROUTER_API_KEY) provider=openrouter ;;
        OPENAI_API_KEY) provider=openai ;;
        *)
            printf '%bNo isolated proxy route is configured for %s. The key will not enter the sandbox.%b\n' "$YELLOW" "$env_name" "$NC"
            return 1
            ;;
    esac

    value="${!env_name}"
    if [[ -z "$value" ]]; then
        printf '%bSkipping %s because its value is empty.%b\n' "$YELLOW" "$env_name" "$NC"
        return 1
    fi

    secret_name="$(random_secret_name "${CONTAINER_NAME}-proxy-${provider}")"
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Would store %s only for the credential proxy. The value is hidden.%b\n' "$BLUE" "$env_name" "$NC"
        run_podman secret create "$secret_name" - || { unset value; return 1; }
    else
        printf '%s' "$value" | run_podman secret create "$secret_name" - || { unset value; return 1; }
    fi
    PROXY_PROVIDERS+=("$provider")
    PROXY_SECRET_NAMES+=("$secret_name")
    unset value
}

add_api_secrets() {
    local env_name provider
    local -a env_vars=()
    while IFS= read -r env_name; do
        if [[ -n "$env_name" ]]; then
            env_vars+=("$env_name")
        fi
    done < <(compgen -e | grep -i 'API_KEY' || true)

    if ((${#env_vars[@]} == 0)); then
        printf 'No exported environment variable names containing API_KEY were found.\n'
        return 0
    fi

    printf 'Found exported API key variable names. Values will not be displayed or passed to the sandbox.\n'
    for env_name in "${env_vars[@]}"; do
        case "$env_name" in
            OPENROUTER_API_KEY) provider=OpenRouter ;;
            OPENAI_API_KEY) provider=OpenAI ;;
            *)
                printf '%s is not supported by the isolated proxy. The key will not be passed through.\n' "$env_name"
                continue
                ;;
        esac
        if confirm "Route $env_name through the isolated $provider proxy" n; then
            add_api_secret_to_proxy "$env_name" || true
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
    if ! prepare_secret "$secret_name" "$source"; then
        return 1
    fi
    if [[ "$WORKSPACE_MODE" == map ]]; then
        ssh_dir="$HOME_HOST/.ssh"
        if [[ -L "$ssh_dir" ]]; then
            printf '%bRefusing to use a symlink as the mounted .ssh directory: %s%b\n' "$RED" "$ssh_dir" "$NC" >&2
            return 1
        fi
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi
    SSH_SECRET_NAME="$secret_name"
}

proxy_is_enabled() {
    [[ -n "$PROXY_CONTAINER_NAME" ]]
}

proxy_base_url() {
    case "$1" in
        openrouter) printf 'http://127.0.0.1:%s/openrouter/api/v1' "$PROXY_PORT" ;;
        openai) printf 'http://127.0.0.1:%s/openai/v1' "$PROXY_PORT" ;;
    esac
}

create_proxy_token_secret() {
    # The token is the only value the sandbox receives in place of a real key.
    # It is stored as a Podman secret for the proxy. It is not written to disk.
    local token
    PROXY_TOKEN_SECRET="$(random_secret_name "${CONTAINER_NAME}-proxy-token")"
    token="sandbox-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    PROXY_TOKEN="$token"
    if [[ "$DRY_RUN" == true ]]; then
        run_podman secret create "$PROXY_TOKEN_SECRET" -
        return 0
    fi
    printf '%s' "$token" | run_podman secret create "$PROXY_TOKEN_SECRET" - || return 1
}

wait_for_credential_proxy() {
    local attempt
    [[ "$DRY_RUN" == true ]] && return 0
    for ((attempt = 0; attempt < 30; attempt++)); do
        if podman exec "$PROXY_CONTAINER_NAME" python3 /opt/credential_proxy.py \
            --check --socket "$PROXY_SOCKET_PATH" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    printf '%bCredential proxy did not become ready.%b\n' "$RED" "$NC" >&2
    return 1
}

create_credential_proxy() {
    local i provider
    local -a args=(run -d --name "$PROXY_CONTAINER_NAME"
        --label io.mypodman.credential-proxy=true
        --network podman
        --http-proxy=false
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --volume "$PROXY_VOLUME_NAME:$PROXY_SOCKET_DIR:U"
        --secret "$PROXY_TOKEN_SECRET,target=$PROXY_TOKEN_TARGET,uid=10001,gid=10001,mode=0400")
    for i in "${!PROXY_PROVIDERS[@]}"; do
        provider="${PROXY_PROVIDERS[$i]}"
        args+=(--secret "${PROXY_SECRET_NAMES[$i]},target=/run/secrets/${provider}-key,uid=10001,gid=10001,mode=0400")
    done
    args+=("$DEFAULT_PROXY_IMAGE" --socket "$PROXY_SOCKET_PATH" --token-file "$PROXY_TOKEN_TARGET")
    for i in "${!PROXY_PROVIDERS[@]}"; do
        provider="${PROXY_PROVIDERS[$i]}"
        args+=("--${provider}-key-file" "/run/secrets/${provider}-key")
    done
    run_podman "${args[@]}"
    wait_for_credential_proxy
}

start_credential_proxy() {
    proxy_is_enabled || return 0
    if [[ "$DRY_RUN" == false ]]; then
        if ! podman container exists "$PROXY_CONTAINER_NAME"; then
            printf '%bCredential proxy container %s was not found.%b\n' "$RED" "$PROXY_CONTAINER_NAME" "$NC" >&2
            return 1
        fi
        if [[ "$(podman inspect --format '{{.State.Running}}' "$PROXY_CONTAINER_NAME")" != true ]]; then
            run_podman start "$PROXY_CONTAINER_NAME"
        fi
    else
        run_podman start "$PROXY_CONTAINER_NAME"
    fi
    wait_for_credential_proxy
}

start_sandbox_bridge() {
    # The bridge runs detached. If an earlier bridge still holds the port,
    # the new one exits quietly and the old one keeps serving.
    local name="$1"
    proxy_is_enabled || return 0
    run_podman exec -d "$name" python3 "$BRIDGE_PATH" \
        --listen 127.0.0.1 --port "$PROXY_PORT" --socket "$PROXY_SOCKET_PATH"
}

verify_sandbox_isolation() {
    # Checks the sandbox from inside. It has no network interface except
    # loopback, direct internet access fails, and the proxy answers through
    # the loopback bridge.
    local name="$1" check_code
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[DRY-RUN] Would verify sandbox isolation.%b\n' "$BLUE" "$NC"
        return 0
    fi
    check_code="$(cat <<'PY'
import os, socket, sys, time, urllib.request

interfaces = sorted(os.listdir("/sys/class/net"))
if interfaces != ["lo"]:
    print("The sandbox has network interfaces other than loopback: " + " ".join(interfaces))
    sys.exit(1)
try:
    socket.create_connection(("1.1.1.1", 443), timeout=3).close()
except OSError:
    pass
else:
    print("Direct internet access succeeded. It must be blocked.")
    sys.exit(1)
url = "http://127.0.0.1:%s/health" % sys.argv[1]
deadline = time.time() + 15
while True:
    try:
        urllib.request.urlopen(url, timeout=3).read()
        break
    except Exception as error:
        if time.time() > deadline:
            print("The loopback bridge to the credential proxy is not reachable: %s" % error)
            sys.exit(1)
        time.sleep(0.5)
PY
)"
    if podman exec "$name" python3 -c "$check_code" "$PROXY_PORT"; then
        printf '%bIsolation check passed.%b\n' "$GREEN" "$NC"
        return 0
    fi
    printf '%bIsolation check failed. The sandbox is not isolated as designed.%b\n' "$RED" "$NC" >&2
    return 1
}

initialize_sandbox() {
    local name="$1" git_name="${2:-}" git_email="${3:-}" mode="${4:-map}" ssh_secret="${5:-}" openrouter_url="${6:-}" openai_url="${7:-}" shell_payload proxy_enabled=0
    if [[ -n "$PROXY_CONTAINER_NAME" ]]; then
        proxy_enabled=1
    fi
    shell_payload='set -eu
if [ -n "$SANDBOX_GIT_NAME" ]; then
  git config --global user.name "$SANDBOX_GIT_NAME"
  jj config set --user user.name "$SANDBOX_GIT_NAME"
fi
if [ -n "$SANDBOX_GIT_EMAIL" ]; then
  git config --global user.email "$SANDBOX_GIT_EMAIL"
  jj config set --user user.email "$SANDBOX_GIT_EMAIL"
fi
if [ "$SANDBOX_WORKSPACE_MODE" = clone ] && [ -n "$SANDBOX_SSH_SECRET_NAME" ]; then
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  rm -rf "$HOME/.ssh/id_ed25519"
  ln -s /run/secrets/sandbox-ssh-key "$HOME/.ssh/id_ed25519"
fi
if [ "$SANDBOX_PROXY_ENABLED" = 1 ]; then
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$HOME/.ssh/config" ]; then
    : > "$HOME/.ssh/config"
  fi
  if ! grep -Fq "ProxyCommand nc -X connect -x 127.0.0.1:8765" "$HOME/.ssh/config"; then
    { printf "Host github.com\\n  ProxyCommand nc -X connect -x 127.0.0.1:8765 %%h %%p\\n  StrictHostKeyChecking accept-new\\n\\n"; cat "$HOME/.ssh/config"; } > "$HOME/.ssh/config.sandbox-wizard"
    chmod 600 "$HOME/.ssh/config.sandbox-wizard"
    mv "$HOME/.ssh/config.sandbox-wizard" "$HOME/.ssh/config"
  fi
fi
if [ -n "$SANDBOX_OPENROUTER_BASE_URL$SANDBOX_OPENAI_BASE_URL" ] && [ -f /usr/local/lib/sandbox/configure_pi_proxy.py ]; then
  python3 /usr/local/lib/sandbox/configure_pi_proxy.py
fi
if [ -d "$HOME/.ssh" ]; then
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$HOME/.ssh/config" ]; then
    printf "Host *\n  StrictHostKeyChecking accept-new\n" > "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
fi'
    run_podman exec \
        -e "SANDBOX_GIT_NAME=$git_name" \
        -e "SANDBOX_GIT_EMAIL=$git_email" \
        -e "SANDBOX_WORKSPACE_MODE=$mode" \
        -e "SANDBOX_SSH_SECRET_NAME=$ssh_secret" \
        -e "SANDBOX_PROXY_ENABLED=$proxy_enabled" \
        -e "SANDBOX_OPENROUTER_BASE_URL=$openrouter_url" \
        -e "SANDBOX_OPENAI_BASE_URL=$openai_url" \
        "$name" /bin/bash -lc "$shell_payload"
}

create_sandbox() {
    local image_user cwd selinux_suffix mount_spec secret_target provider openrouter_url="" openai_url="" token
    local -a args
    reset_sandbox_config
    cwd="$(pwd -P)"
    HOME_HOST="$cwd"

    printf 'Workspace mode:\n'
    printf '  map   Share the current directory with the container.\n'
    printf '  clone Copy the current directory into container-only storage.\n'
    prompt_input "Workspace mode" "map"
    WORKSPACE_MODE="$REPLY"
    if [[ "$WORKSPACE_MODE" != map && "$WORKSPACE_MODE" != clone ]]; then
        printf '%bChoose map or clone.%b\n' "$RED" "$NC" >&2
        return 1
    fi
    if [[ "$WORKSPACE_MODE" == clone ]]; then
        printf 'Clone mode copies all files, including hidden files. Later host changes are not copied.\n'
        confirm "Copy this directory into the container" y || return 1
    fi

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
        if [[ "$WORKSPACE_MODE" == map ]]; then
            printf '%bWarning: this mounts your host home directory over the container home.%b\n' "$YELLOW" "$NC" >&2
        else
            printf '%bWarning: clone mode copies your full host home, including hidden files, into the container.%b\n' "$YELLOW" "$NC" >&2
        fi
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

    # The sandbox has no network interface. The proxy is the only way out.
    PROXY_CONTAINER_NAME="${CONTAINER_NAME}-credential-proxy"
    PROXY_VOLUME_NAME="${CONTAINER_NAME}-proxy-socket"
    create_proxy_token_secret
    token="$PROXY_TOKEN"
    unset PROXY_TOKEN
    run_podman volume create "$PROXY_VOLUME_NAME"
    create_credential_proxy

    for provider in "${PROXY_PROVIDERS[@]}"; do
        case "$provider" in
            openrouter) openrouter_url="$(proxy_base_url openrouter)" ;;
            openai) openai_url="$(proxy_base_url openai)" ;;
        esac
    done

    selinux_suffix=""
    if [[ "$(uname -s)" == Linux ]]; then
        selinux_suffix=",Z"
    fi
    mount_spec="$HOME_HOST:$HOME_CONTAINER:rw$selinux_suffix"

    args=(run -d -it --name "$CONTAINER_NAME"
        --label io.mypodman.sandbox=true
        --http-proxy=false
        --network none
        --userns=keep-id:uid=1000,gid=1000
        --user 1000:1000
        --volume "$PROXY_VOLUME_NAME:$PROXY_SOCKET_DIR"
        --env "HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT"
        --env "https_proxy=http://127.0.0.1:$PROXY_PORT")
    if [[ "$WORKSPACE_MODE" == map ]]; then
        args+=(--volume "$mount_spec")
    fi
    if ((${#PROXY_PROVIDERS[@]} > 0)); then
        args+=(--env PI_CODING_AGENT_DIR=/var/lib/sandbox/pi-agent)
    fi
    if [[ -n "$openrouter_url" ]]; then
        args+=(--env "OPENROUTER_API_KEY=$token" --env "OPENROUTER_BASE_URL=$openrouter_url")
    fi
    if [[ -n "$openai_url" ]]; then
        args+=(--env "OPENAI_API_KEY=$token" --env "OPENAI_BASE_URL=$openai_url")
    fi
    args+=(--workdir "$HOME_CONTAINER")
    if [[ -n "$SSH_SECRET_NAME" ]]; then
        if [[ "$WORKSPACE_MODE" == clone ]]; then
            secret_target=/run/secrets/sandbox-ssh-key
        else
            secret_target="$HOME_CONTAINER/.ssh/id_ed25519"
        fi
        args+=(--secret "$SSH_SECRET_NAME,target=$secret_target,uid=1000,gid=1000,mode=0400")
    fi
    args+=("$IMAGE" sleep infinity)
    run_podman "${args[@]}"
    unset token

    if [[ "$WORKSPACE_MODE" == clone ]]; then
        run_podman cp "$HOME_HOST/." "$CONTAINER_NAME:$HOME_CONTAINER/"
        run_podman exec --user 0:0 "$CONTAINER_NAME" chown -R --no-dereference 1000:1000 "$HOME_CONTAINER"
    fi
    initialize_sandbox "$CONTAINER_NAME" "$GIT_NAME" "$GIT_EMAIL" "$WORKSPACE_MODE" "$SSH_SECRET_NAME" "$openrouter_url" "$openai_url"
    # Save before the check so a failed sandbox can still be removed with rm.
    save_sandbox_config "$CONTAINER_NAME"
    start_sandbox_bridge "$CONTAINER_NAME"
    verify_sandbox_isolation "$CONTAINER_NAME"
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
    local name="${1:-}" shell="${2:-}" provider openrouter_url="" openai_url=""
    if [[ -z "$name" ]]; then
        select_running_container || return 1
        name="$REPLY"
    fi
    if load_sandbox_config "$name"; then
        shell="${shell:-$SANDBOX_SHELL}"
        start_credential_proxy
        for provider in "${PROXY_PROVIDERS[@]}"; do
            case "$provider" in
                openrouter) openrouter_url="$(proxy_base_url openrouter)" ;;
                openai) openai_url="$(proxy_base_url openai)" ;;
            esac
        done
        initialize_sandbox "$name" "$GIT_NAME" "$GIT_EMAIL" "$WORKSPACE_MODE" "$SSH_SECRET_NAME" "$openrouter_url" "$openai_url"
        start_sandbox_bridge "$name"
    else
        # No saved configuration. Do not reuse proxy state from an earlier menu action.
        reset_sandbox_config
        shell="${shell:-/bin/bash}"
        initialize_sandbox "$name" "" ""
    fi
    run_podman exec -it "$name" "$shell"
}

start_sandbox() {
    local name="$1"
    if load_sandbox_config "$name"; then
        start_credential_proxy
    fi
    run_podman start "$name"
    if load_sandbox_config "$name"; then
        start_sandbox_bridge "$name"
    fi
}

stop_sandbox() {
    local name="$1"
    run_podman stop "$name"
    if load_sandbox_config "$name" && proxy_is_enabled; then
        run_podman stop "$PROXY_CONTAINER_NAME"
    fi
}

remove_sandbox() {
    local name="$1" secret_name
    if load_sandbox_config "$name"; then
        :
    else
        reset_sandbox_config
        if [[ "$DRY_RUN" == false ]] && podman container exists "${name}-credential-proxy"; then
            PROXY_CONTAINER_NAME="${name}-credential-proxy"
            PROXY_VOLUME_NAME="${name}-proxy-socket"
            printf '%bNo saved configuration for %s. Its proxy secrets cannot be identified; remove them with secrets rm.%b\n' "$YELLOW" "$name" "$NC" >&2
        fi
    fi

    run_podman rm "$name"
    if proxy_is_enabled; then
        run_podman rm -f "$PROXY_CONTAINER_NAME"
    fi
    if [[ -n "$PROXY_VOLUME_NAME" ]]; then
        run_podman volume rm "$PROXY_VOLUME_NAME"
    fi
    # Configurations from before the Unix-socket proxy used a per-sandbox
    # network. Remove that network if it is still present.
    if [[ -n "${NETWORK_NAME:-}" ]] && { [[ "$DRY_RUN" == true ]] || podman network exists "$NETWORK_NAME"; }; then
        run_podman network rm "$NETWORK_NAME"
    fi
    # Secret removal is best effort. One failure should not leave the
    # network, volume, or config behind.
    if [[ -n "$PROXY_TOKEN_SECRET" ]]; then
        run_podman secret rm "$PROXY_TOKEN_SECRET" || printf '%bCould not remove secret %s.%b\n' "$YELLOW" "$PROXY_TOKEN_SECRET" "$NC" >&2
    fi
    for secret_name in ${PROXY_SECRET_NAMES[@]+"${PROXY_SECRET_NAMES[@]}"}; do
        run_podman secret rm "$secret_name" || printf '%bCould not remove secret %s.%b\n' "$YELLOW" "$secret_name" "$NC" >&2
    done
    if [[ "$DRY_RUN" == false && -f "$(config_path "$name")" ]]; then
        rm -- "$(config_path "$name")"
    fi
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
                if load_sandbox_config "$name" && proxy_is_enabled && [[ "$DRY_RUN" == false ]] && podman container exists "$CONTAINER_NAME"; then
                    printf 'This configuration tracks a live credential proxy. Remove the sandbox with the rm command first.\n' >&2
                    return 1
                fi
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
  build                      Build the development and credential proxy images
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
  Choose map to share the current directory, or clone to copy it into container-only storage.
  Clone copies hidden files too. Later host changes are not copied into the container.
  Choose whether to route exported OPENROUTER_API_KEY or OPENAI_API_KEY values through the proxy.
  The wizard displays variable names only. The sandbox receives a fake token, not the real key.
  The sandbox has no network interface. Its only route out is the credential proxy.
  The proxy forwards supported API requests and selected GitHub and package traffic.
  The wizard asks separately whether to mount an SSH private key.

Secrets:
  secrets ls lists secrets stored by Podman. It does not show container mappings.
  API keys are mounted only into the proxy container. SSH keys are mounted into the sandbox and remain readable there.

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
            case "$command" in
                start) start_sandbox "$1" ;;
                stop) stop_sandbox "$1" ;;
                rm) remove_sandbox "$1" ;;
            esac
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
                    6) start_sandbox "$REPLY" ;;
                    7) stop_sandbox "$REPLY" ;;
                    8) remove_sandbox "$REPLY" ;;
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
