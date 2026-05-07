# Manual Podman Commands

This document contains manual Podman commands for advanced usage and reference.

## Enter a container

```bash
podman exec -it erlang_m1_dev bash
```

## Create and run a new container

This command maps the home directory inside the container and keeps the
same userid inside the container as we have on the Host.

```bash
podman run --name=trunk --userns=keep-id -v /home/tobbe:/home/tobbe -it registry.lab.tail-f.com:5000/jenkins-doc:17-2404 /bin/bash
```

## Map ports between container and host

Use `-p` to forward a host port to a container port:

```bash
podman run --name=trunk --userns=keep-id -v /home/tobbe:/home/tobbe -p 8080:8080 -it registry.lab.tail-f.com:5000/jenkins-doc:17-2404 /bin/bash
```

Multiple ports can be mapped by repeating `-p`:

```bash
podman run --name=trunk --userns=keep-id -v /home/tobbe:/home/tobbe -p 8080:8080 -p 2024:2024 -it registry.lab.tail-f.com:5000/jenkins-doc:17-2404 /bin/bash
```

## Start a stopped container

```bash
podman start trunk
```

## Enter a running container

```bash
podman exec -it trunk /bin/bash
```

## Stop a running container

```bash
podman stop trunk
```

## List containers

```bash
podman ps          # running containers
podman ps -a       # all containers (including stopped)
```

## Remove a container

```bash
podman rm trunk
```

## List images

```bash
podman images
```

## Save a container as a new image

If you've installed packages or made changes inside the container that
you want to keep, commit it as a new image:

```bash
podman commit trunk registry.lab.tail-f.com:5000/jenkins-doc:17-2404-custom
```

## Remove an image

```bash
podman rmi registry.lab.tail-f.com:5000/jenkins-doc:17-2404
```

## Push an image to GitHub Container Registry

### 1. Create a GitHub Personal Access Token (PAT)

Create a token at https://github.com/settings/tokens with `write:packages` scope.

Quick example:

```bash
echo $GITHUB_PODMAN_TOKEN | podman login ghcr.io -u etnt --password-stdin
podman images
podman tag 5ef9b21a6bba ghcr.io/etnt/mac-erlang-dev:v1
podman images
podman push ghcr.io/etnt/mac-erlang-dev:v1
```
### 2. Login to GitHub Container Registry

```bash
echo $GITHUB_TOKEN | podman login ghcr.io -u USERNAME --password-stdin
```

Replace `USERNAME` with your GitHub username and `$GITHUB_TOKEN` with your PAT.

### 3. Tag your image

Tag the image with the GitHub Container Registry format:

```bash
podman tag LOCAL_IMAGE ghcr.io/USERNAME/IMAGE_NAME:TAG
```

Example:
```bash
podman tag myapp:latest ghcr.io/ttornkvi/myapp:latest
```

### 4. Push the image

```bash
podman push ghcr.io/USERNAME/IMAGE_NAME:TAG
```

Example:
```bash
podman push ghcr.io/ttornkvi/myapp:latest
```

### 5. Make the package public (optional)

By default, packages are private. To make it public:
1. Go to https://github.com/USERNAME?tab=packages
2. Select your package
3. Click "Package settings"
4. Scroll down and click "Change visibility"
