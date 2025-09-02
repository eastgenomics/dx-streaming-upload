FROM ubuntu:20.04

LABEL title="dx-streaming-upload" \
      description="The DNAnexus incremental upload script packaged as an Ansible Role"

# Disable prompt during packages installation
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /root

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
RUN python3 -m pip install --no-cache-dir -r /root/dx-streaming-upload/requirements.txt && \
    find /usr/local/lib/python3.* -type f -name '*.pyc' -delete && \
    find /usr/local/lib/python3.* -type d -name '__pycache__' -prune -exec rm -rf {} + && \
    rm -rf /root/.cache/pip

# Remove pip install requirements from Ansible tasks to allow running on air-gapped system
RUN sed -i '3,5s%^%#%' /root/dx-streaming-upload/tasks/main.yml

RUN mkdir -p /var/log/dx-streaming-upload/monitor_log_backups

# Add in cron entry for making hourly monitor log backups (see #41)
RUN crontab -u root /root/dx-streaming-upload/cron/crontab

# Ensure cron runs, add env variables to /etc/environment - required for cron to access
CMD service cron start; printenv >> /etc/environment; /bin/bash
