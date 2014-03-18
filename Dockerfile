FROM progrium/cedarish
MAINTAINER Fabio Rehm "fgrehm@gmail.com"

#####################################################################
# Create a default user to avoid using the container as root, we set
# the user and group ids to 1000 as it is the most common ids for
# single user Ubuntu machines.
# The provided /usr/bin/fix-permissions script can be used at startup
# to ensure the 'developer' user id / group id are the same as the
# directory bind mounted into the container.
RUN mkdir -p /.devstep/cache && \
    mkdir -p /.devstep/.profile.d && \
    mkdir -p /.devstep/bin && \
    mkdir -p /.devstep/log && \
    mkdir -p /workspace && \
    echo "developer:x:1000:1000:Developer,,,:/.devstep:/bin/bash" >> /etc/passwd && \
    echo "developer:x:1000:" >> /etc/group && \
    echo "developer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/developer && \
    chmod 0440 /etc/sudoers.d/developer

#####################################################################
# Init script based on phusion/baseimage-docker's

RUN DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y runit python && \
    mkdir -p /etc/service && \
    mkdir -p /etc/my_init.d && \
    mkdir -p /etc/container_environment

#####################################################################
# Install and configure PostgreSQL and MySQL clients
RUN DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y postgresql-client mysql-client

RUN echo "[client]\nprotocol=tcp\nuser=root" >> /.devstep/.my.cnf && \
    echo "export PGHOST=localhost" >> /.devstep/.profile.d/postgresql.sh && \
    echo "export PGUSER=postgres" >> /.devstep/.profile.d/postgresql.sh && \
    echo "localhost" > /etc/container_environment/PGHOST

#####################################################################
# Download and install jq as it is being used by a few buildpacks
# See http://stedolan.github.io/jq for more info
RUN mkdir -p /.devstep/bin && \
    curl -L -s http://stedolan.github.io/jq/download/linux64/jq > /.devstep/bin/jq && \
    chmod +x /.devstep/bin/jq

#####################################################################
# Fix permissions
RUN chown -R developer:developer /.devstep && \
    chown -R developer:developer /workspace && \
    chown -R developer:developer /etc/service && \
    chown -R developer:developer /etc/my_init.d && \
    chown -R developer:developer /etc/container_environment

#####################################################################
# Devstep goodies (ADDed at the end to increase image "cacheability")

ADD stack/bashrc /.devstep/.bashrc
ADD stack/fix-permissions /usr/bin/fix-permissions
ADD stack/my-init /usr/bin/my-init
ADD stack/forward-ports /usr/bin/forward-ports
ADD stack/load-devstep-env /.devstep/load-env.sh
ADD stack/hack /.devstep/bin/hack
ADD builder/build.sh /.devstep/bin/build-project
ADD buildpacks /.devstep/buildpacks
ADD https://godist.herokuapp.com/projects/ddollar/forego/releases/current/linux-amd64/forego /.devstep/bin/forego

RUN chmod +x /usr/bin/fix-permissions && \
    chmod +x /usr/bin/my-init && \
    chmod +x /usr/bin/forward-ports && \
    chmod +x /.devstep/bin/forego && \
    chmod +x /.devstep/bin/build-project && \
    chmod +x /.devstep/bin/hack && \
    chmod u+s /usr/bin/sudo && \
    echo 'source /.devstep/load-env.sh' > /etc/my_init.d/load-devstep-env.sh && \
    ln -s /usr/bin/fix-permissions /etc/my_init.d/fix-permissions.sh && \
    ln -s /usr/bin/forward-ports /etc/my_init.d/forward-ports.sh

USER developer
ENV HOME /.devstep
