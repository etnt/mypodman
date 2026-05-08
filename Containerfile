FROM debian:testing-slim

# Install Erlang and basic dev tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    erlang-base erlang-dev erlang-dialyzer \
    rebar3 git bash ca-certificates sudo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create the 'ttornkvi' user matching host UID/GID
# -m creates home, -s sets shell, -u 501 -g 20 matches macOS host user
RUN groupadd -g 20 hostgroup || true \
    && useradd -ms /bin/bash -u 501 -g 20 ttornkvi \
    && echo "ttornkvi ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER ttornkvi
WORKDIR /home/ttornkvi
