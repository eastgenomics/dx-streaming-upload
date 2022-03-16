FROM ubuntu:20.04

# disable prompt during packages installation
ARG DEBIAN_FRONTEND=noninteractive

RUN apt update 
RUN apt install ansible cron software-properties-common git nano python3 python3-dev python3-pip -y
RUN python3 -m pip install --upgrade pip
RUN pip3 install --upgrade --ignore-installed pyyaml
RUN pip3 install dxpy

RUN cron

RUN useradd -m dx-upload -u 1005 -s /bin/bash -d /home/dx-upload
RUN chown -R 1005 /opt/
RUN su - dx-upload

RUN touch /var/run/crond.pid
RUN chown 1005 /var/run/crond.pid
RUN chmod gu+rw /var/run
RUN chmod gu+s /usr/sbin/cron

RUN mkdir /home/dx-upload/runs
RUN mkdir /home/dx-upload/logs
RUN mkdir /home/dx-upload/tars


