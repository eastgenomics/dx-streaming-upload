FROM ubuntu:20.04

# disable prompt during packages installation
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt install ansible cron rsyslog software-properties-common git nano python3 \
    python3-dev python3-pip sudo jq tree -y
COPY requirements.txt .
RUN pip install -r requirements.txt
RUN pip3 install --upgrade --ignore-installed -r requirements.txt

# add a user to run uploads with, set permissions so both user and root
# can run uploads as user
RUN useradd -m dx-upload -u 1005 -s /bin/bash -d /home/dx-upload
RUN chown -R 1005 /opt/
RUN chmod 777 /var/lock/
RUN chmod -R 777 /home/dx-upload/
RUN mkdir -p /var/log/dx-streaming-upload
RUN chmod 777 /var/log/dx-streaming-upload
RUN su - dx-upload

# copy in dx-streaming-upload
COPY . /home/dx-upload/dx-streaming-upload
COPY . /opt/dx-streaming-upload

# comment out lines that install dx requirements on running since they are installed above
RUN sed -i '3,5s%^%#%' /home/dx-upload/dx-streaming-upload/tasks/main.yml

# allow dx-upload user to run cron jobs
RUN touch /var/run/crond.pid
RUN chown 1005 /var/run/crond.pid
RUN chmod gu+rw /var/run
RUN chmod gu+s /usr/sbin/cron
RUN chown 1005 /etc/environment

# add in cron entry for making hourly monitor log backups
COPY cron/crontab /etc/cron.d/crontab
RUN chmod 0644 /etc/cron.d/crontab
RUN crontab /etc/cron.d/crontab

# create required log dir, playbook(s) should point to here
RUN mkdir /home/dx-upload/logs
RUN chown -R dx-upload /home/dx-upload

# adding env variables to /etc/environment required for cron to access
WORKDIR /home/dx-upload/
CMD service cron start; printenv >> /etc/environment; /bin/bash
