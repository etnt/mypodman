FROM debian:testing-slim

# Install Erlang and basic dev tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    erlang-base erlang-dev erlang-dialyzer \
    rebar3 git bash ca-certificates sudo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create the 'tobbe' user
# -m creates home, -s sets shell, -u 1000 is standard for the first non-root user
RUN useradd -ms /bin/bash -u 1000 tobbe \
    && echo "tobbe ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER tobbe
WORKDIR /home/tobbe
