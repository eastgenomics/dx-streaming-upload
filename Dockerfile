FROM ubuntu:20.04

# disable prompt during packages installation
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt install ansible cron rsyslog software-properties-common git nano python3 python3-dev python3-pip sudo -y
RUN python3 -m pip install --upgrade pip
RUN pip3 install --upgrade --ignore-installed pyyaml dxpy beautifulsoup4 lxml

RUN cron

# add a user to run uploads with, set permissions so both user and root
# can run uploads as user
RUN useradd -m dx-upload -u 1005 -s /bin/bash -d /home/dx-upload
RUN chown -R 1005 /opt/
RUN chmod 777 /var/lock/
RUN chmod -R 777 /home/dx-upload/
RUN mkdir -p /var/log/dx-streaming-upload
RUN chmod 777 /var/log/dx-streaming-upload
RUN su - dx-upload

# create a dir with permissions to bind host data dir to, playbooks can refer to here
RUN mkdir -p /genetics
RUN chmod 777 /genetics

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


# create required log dir, playbook(s) should point to here
RUN mkdir /home/dx-upload/logs
RUN chown -R dx-upload /home/dx-upload

WORKDIR /home/dx-upload/
ENTRYPOINT /bin/bash
