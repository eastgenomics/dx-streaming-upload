#! /bin/bash
# Script to run in the built docker image to test dx-streaming-upload
# 2 instances of dx-streaming-upload are set up to simulate 2 sequencers
# being monitored concurrently

# We expect A01295 to upload successfully and send a success notification to
# the logs channel, and A01303 to send an alert due to missing cycle dirs

# $1 -> project-id to upload to
# $2 -> dx-token

set -e

main() {
    # add passed project id to playbook
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/test-playbook-template.yml | \
        sed -r "s/(upload_project:).*/\1 $1/g" > /home/dx-upload/dx-streaming-upload/docker-tests/test-playbook.yml

    # add slack token and proxy to /etc/environment for cron to access
    if [ ! $(grep 'SLACK' /etc/environment) ]; then
        printenv | grep SLACK >> /etc/environment
    fi

    if [ ! $(grep 'proxy' /etc/environment) ]; then
        printenv | grep -i proxy >> /etc/environment
    fi

    A01295="A01295_${RANDOM}_test_upload"
    A01303="A01303_${RANDOM}_test_upload"

    printf "\nCreating test runs:\n\t${A01295}\n\t${A01303}\n"

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    printf "\nCreating example directory structure...\n"
    mkdir -p /home/dx-upload/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/L001/C318.1
    mkdir -p /home/dx-upload/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L001/C123.1

    # going to create RTAComplete.txt and CopyComplete.txt so it can test for both NovaSeq True/False
    # in config, in practice only one will be written and checked for in incremental_upload.py
    touch /home/dx-upload/genetics/A01295/${A01295}/SampleSheet.csv \
          /home/dx-upload/genetics/A01295/${A01295}/RTAComplete.txt \
          /home/dx-upload/genetics/A01295/${A01295}/CopyComplete.txt

    touch /home/dx-upload/genetics/A01303/${A01303}/SampleSheet.csv \
          /home/dx-upload/genetics/A01303/${A01303}/RTAComplete.txt \
          /home/dx-upload/genetics/A01303/${A01303}/CopyComplete.txt

    # create RunInfo.xml files with IDs added
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01295}\">/g" > /home/dx-upload/genetics/A01295/${A01295}/RunInfo.xml
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01303}\">/g" > /home/dx-upload/genetics/A01303/${A01303}/RunInfo.xml

    # trigger Ansible
    printf "\n\nStarting dx-streaming-upload\n\n"
    ansible-playbook /home/dx-upload/dx-streaming-upload/docker-tests/test-playbook.yml -v --extra-vars "dx_token=$2"

    # start cron
    printf "\nStarting cron:\n\n"
    service cron start

    # create some files with enough size (2GB each) to trigger an upload
    printf "\nCreating test files...\n\n"
    dd if=/dev/urandom of=/home/dx-upload/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/L001/C318.1/output.dat  bs=1000 count=2000000
    dd if=/dev/urandom of=/home/dx-upload/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L001/C123.1/output.dat  bs=1000 count=2000000

    printf "\nDone! The docker container should now be running, and uploads starting for 2 test uploads.\n"
    printf "A01295 should upload successfully, and A01303 should fail due to incomplete run cycle dirs.\n"
}

main "$1" "$2"
