# Credential isolation proxy

Credential isolation keeps real API keys out of the development container. A credential proxy is a trusted service that forwards requests and adds the real key.

The sandbox image uses a separate Podman container for this proxy. The proxy container receives API keys from Podman secrets. The development container receives a random fake token and the proxy address.

## Network design

The development container has no network interface except loopback (`--network none`). It has no route to the internet, to the Podman gateway, or to the host.

The credential proxy listens on a Unix socket. The socket lives in a Podman volume. Only the proxy container and its sandbox mount this volume. Podman does not publish a port for the proxy.

A small bridge program runs inside the sandbox. It listens on `127.0.0.1:8765` and passes each connection to the proxy socket. The sandbox sets `HTTPS_PROXY` to this address. The wizard starts the bridge when it creates, starts, or enters a sandbox.

An earlier design used an internal Podman network. That network did not block the gateway address. A sandbox on it could reach services on the Podman machine, for example SSH on port 22. The Unix socket design closes this gap.

The proxy accepts API routes for OpenRouter and OpenAI. It adds the real key to an allowlisted API request. It does not accept arbitrary target URLs. It also permits HTTPS tunnels to selected GitHub and package hosts. It rejects other destinations. The proxy refuses request bodies that use chunked transfer encoding. Clients must send `Content-Length`.

## Create a sandbox

Export a supported key before you create the sandbox:

```sh
export OPENROUTER_API_KEY=your-key
./sandbox/sandbox-wizard.sh build
./sandbox/sandbox-wizard.sh create
```

The wizard displays supported environment variable names, not their values. Select the keys that the proxy can use. The wizard sends each selected value to Podman through standard input. It does not write the value to the project, image, command line, or sandbox environment.

Podman stores each key as a secret. The proxy container mounts the secret as a read-only file. The proxy process reads the file when it starts. The sandbox does not mount this file.

The wizard also stores a random fake token as a Podman secret. The proxy reads it from a file, so it never appears in a process list. The sandbox receives the same token in `OPENROUTER_API_KEY` or `OPENAI_API_KEY`. The wizard sets the provider address to the bridge at `127.0.0.1:8765`. It sets only the variables for providers that you selected. An OpenRouter key does not create `OPENAI_*` variables. Pi gets a private models configuration in `/var/lib/sandbox/pi-agent` that points its provider to the proxy.

The wizard does not pass other `*_API_KEY` values into the sandbox. It reports that those providers are not supported by the isolated proxy.

## Test key isolation

Run these commands inside the sandbox:

```sh
printenv OPENROUTER_API_KEY
curl -i https://openrouter.ai
```

The first command prints a fake token. It does not print the real key. The second command fails because the sandbox has no direct network access.

The wizard runs a check after it creates a sandbox. The check confirms that loopback is the only network interface, that a direct connection to the internet fails, and that the proxy answers through the bridge. If the check fails, the wizard reports an error. Remove the sandbox with `rm`.

The sandbox can send an API request through the proxy. The proxy checks the fake token and forwards supported paths to the provider. Code in the sandbox can use this service and spend the key's quota, but it cannot read the key.

## GitHub and SSH access

The proxy permits HTTPS connections to selected GitHub hosts and SSH connections to `github.com` on port 22. The sandbox sends SSH traffic through the bridge and the proxy with `nc`. The sandbox SSH configuration sets `StrictHostKeyChecking accept-new`, so SSH trusts the GitHub host key the first time it sees it.

The SSH private key is a separate Podman secret mounted into the development container. Code in the sandbox can read that key. The proxy does not hide SSH keys.

GitHub CLI and Copilot CLI can save their own login tokens under the mounted home. Keep those files out of source control.

## Manage the sandbox

Use the wizard to stop, start, and remove the sandbox. The wizard also stops, starts, or removes its credential proxy and socket volume. Stop a sandbox before you remove it.

The wizard always saves a sandbox configuration in `~/.config/sandbox-wizard/`. It needs this file to restart and remove the proxy. The file holds secret names, not secret values.

Removing the sandbox removes its API-key and token secrets. If one secret cannot be removed, the wizard reports it and continues with the rest. The SSH key secret remains in Podman. List stored secrets with:

```sh
./sandbox/sandbox-wizard.sh secrets ls
```

The list shows stored Podman secrets. It does not show which containers use them.

## Limits and migration

The proxy accepts API calls from code in the sandbox. Set provider quota limits to reduce unexpected charges.

Allowed hosts can carry data out of the sandbox. For example, code can use `api.github.com` or `github.com` with the SSH key or a saved GitHub login to send data to a repository or gist that you do not control. Credential isolation protects API keys. It does not stop code from copying files that it can read.

The proxy allows HTTPS connections only to selected GitHub and package hosts, and to `pi.dev` for `pi update`. It blocks direct internet access to other hosts. Add a destination to the proxy allowlist only when the sandbox needs it.

This setup does not update existing containers. Remove and recreate each sandbox that received a real API key. Remove old API-key secrets after no container uses them. Rotate a key if untrusted code could read it.
