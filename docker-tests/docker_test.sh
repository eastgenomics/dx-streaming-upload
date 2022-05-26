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
    cat ~/dx-streaming-upload/docker-tests/test_files/test-playbook-template.yml | \
        sed -r "s/(upload_project:).*/\1 $1/g" > ~/dx-streaming-upload/docker-tests/test-playbook.yml

    printenv | grep SLACK >> /etc/environment

    A01295="A01295_${RANDOM}_test_upload"
    A01303="A01303_${RANDOM}_test_upload"

    printf "\nCreating test runs:\n\t${A01295}\n\t${A01303}\n"

    # create example dir structure
    printf "\nCreating example directory structure...\n\n"
    mkdir -p ~/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/
    mkdir -p ~/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    mkdir -p ~/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/C318.1
    mkdir -p ~/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/C123.1

    # going to create RTAComplete.txt and CopyComplete.txt so it can test for both NovaSeq True/False
    # in config, in practice only one will be written and checked for in incremental_upload.py
    touch ~/genetics/A01295/${A01295}/SampleSheet.csv \
          ~/genetics/A01295/${A01295}/RTAComplete.txt \
          ~/genetics/A01295/${A01295}/CopyComplete.txt

    touch ~/genetics/A01303/${A01303}/SampleSheet.csv \
          ~/genetics/A01303/${A01303}/RTAComplete.txt \
          ~/genetics/A01303/${A01303}/CopyComplete.txt

    # create RunInfo.xml files with IDs added
    cat ~/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01295}\">/g" > ~/genetics/A01295/${A01295}/RunInfo.xml
    cat ~/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01303}\">/g" > ~/genetics/A01303/${A01303}/RunInfo.xml

    # trigger Ansible
    printf "\n\nStarting dx-streaming-upload\n\n"
    ansible-playbook ~/dx-streaming-upload/docker-tests/test-playbook.yml -v --extra-vars "dx_token=$2"

    # start cron
    service start cron

    # create some files with enough size (2GB each) to trigger an upload
    printf "\nCreating test files...\n\n"
    dd if=/dev/urandom of=~/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/C318.1/output.dat  bs=1000 count=2000000
    dd if=/dev/urandom of=~/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/C123.1/output.dat  bs=1000 count=2000000

}

main $1 $2

