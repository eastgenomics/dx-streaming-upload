FROM ubuntu:20.04

LABEL title="dx-streaming-upload" \
      description="The DNAnexus incremental upload script packaged as an Ansible Role"

# Disable prompt during packages installation
ARG DEBIAN_FRONTEND=noninteractive

COPY . /root/dx-streaming-upload

# - Update Ubuntu and install required packages
# - Delete cached build files
RUN apt-get update && \
    apt install --no-install-recommends --assume-yes \
        ansible \
        cron \
        jq \
        nano \
        python3 \
        python3-dev \
        python3-pip \
        rsyslog \
        sudo \
        tree && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# - Install required Python packages
# - Delete cached build files
RUN pip install -r /root/dx-streaming-upload/requirements.txt && \
    find /usr/local/lib/python3.8  \( -iname '*.c' -o -iname '*.pxd' -o -iname '*.pyd' -o -iname '__pycache__' \) | \
        xargs rm -rf {} && \
    rm -rf /root/.cache/pip

# Remove pip install requirements from Ansible tasks to allow running on air-gapped system
RUN sed -i '3,5s%^%#%' /root/dx-streaming-upload/tasks/main.yml

RUN mkdir -p /var/log/dx-streaming-upload/monitor_log_backups

# - Add in cron entry for making hourly monitor log backups (see #41)
# - Adding env variables to /etc/environment required for cron to access
COPY cron/crontab /etc/cron.d/crontab
RUN crontab /etc/cron.d/crontab
CMD service cron start; printenv >> /etc/environment; /bin/bash

WORKDIR /root
