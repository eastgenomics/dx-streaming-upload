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

    # create example dir structure
    mkdir -p ~/genetics/A01295/test_A01295_novaseq/Data/Intensities/BaseCalls/
    mkdir -p ~/genetics/A01303/test_A01303_novaseq/Data/Intensities/BaseCalls/

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    mkdir -p ~/genetics/A01295/test_A01295_novaseq/Data/Intensities/BaseCalls/C318.1
    mkdir -p ~/genetics/A01303/test_A01303_novaseq/Data/Intensities/BaseCalls/C123.1

    touch ~/genetics/A01295/test_A01295_novaseq/SampleSheet.csv \
          ~/genetics/A01295/test_A01295_novaseq/RTAComplete.txt

    touch ~/genetics/A01303/test_A01303_novaseq/SampleSheet.csv \
          ~/genetics/A01303/test_A01303_novaseq/RTAComplete.txt

    # create RunInfo.xml files with IDs added
    cat ~/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"A01295\">/g" > ~/genetics/A01295/test_A01295_novaseq/RunInfo.xml
    cat ~/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"A01303\">/g" > ~/genetics/A01303/test_A01303_novaseq/RunInfo.xml

    # create some files with enough size to trigger an upload
    dd if=/dev/zero of=~/genetics/A01295/test_A01295_novaseq/output.dat  bs=200M count=10
    dd if=/dev/zero of=~/genetics/A01303/test_A01303_novaseq/output.dat  bs=200M count=10

    # trigger Ansible
    cd ~
    ansible-playbook ~/dx-streaming-upload/docker-tests/test-playbook.yml --extra-vars "dx_token=$2"
}

main $1 $2

