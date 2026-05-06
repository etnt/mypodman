# Podman commands

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
