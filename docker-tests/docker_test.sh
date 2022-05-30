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

    if [[ -z $2 ]]; then
        printf "\ndx project and/or token not provided\n"
        printf "\nscript must be run as bash /home/dx-upload/dx-streaming-upload/docker-tests/docker_test.sh {dnanexus-project-id} {dnanexus-auth-token}\n"
        printf "\n\nExiting now\n"
        exit 1
    fi

    # add slack token and proxy to /etc/environment for cron to access
    printenv | grep SLACK >> /etc/environment
    echo "HTTP_PROXY=${HTTP_PROXY}" >> /etc/environment
    echo "HTTPS_PROXY=${HTTPS_PROXY}" >> /etc/environment
    echo "http_proxy=${http_proxy}" >> /etc/environment
    echo "https_proxy=${https_proxy}" >> /etc/environment

    # printenv | grep -i proxy >> /etc/environment
    # slack=$(grep 'SLACK' /etc/environment)
    # if [[ -z "$slack" ]]; then
    #     printf "Addign slack token to /etc"
    #     printenv | grep SLACK >> /etc/environment
    # fi

    # proxy=$(grep -i 'proxy' /etc/environment)
    # if [[ -z "$proxy" ]]; then
    #     printenv | grep -i proxy >> /etc/environment
    # fi

    A01295="A01295_${RANDOM}_test_upload"
    A01303="A01303_${RANDOM}_test_upload"

    printf "\nCreating test runs:\n\t${A01295}\n\t${A01303}\n"

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    printf "\nCreating example directory structure...\n"
    mkdir -p /genetics/A01295/${A01295}/Data/Intensities/BaseCalls/L001/C318.1
    mkdir -p /genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L001/C123.1
    mkdir -p /genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L002/C166.1

    # going to create RTAComplete.txt and CopyComplete.txt so it can test for both NovaSeq True/False
    # in config, in practice only one will be written and checked for in incremental_upload.py
    touch /genetics/A01295/${A01295}/SampleSheet.csv \
          /genetics/A01295/${A01295}/RTAComplete.txt \
          /genetics/A01295/${A01295}/CopyComplete.txt

    touch /genetics/A01303/${A01303}/SampleSheet.csv \
          /genetics/A01303/${A01303}/RTAComplete.txt \
          /genetics/A01303/${A01303}/CopyComplete.txt

    # create RunInfo.xml files with IDs added
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01295}\">/g" > /genetics/A01295/${A01295}/RunInfo.xml
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01303}\">/g" > /genetics/A01303/${A01303}/RunInfo.xml

    # trigger Ansible
    printf "\n\nStarting dx-streaming-upload\n\n"
    ansible-playbook /home/dx-upload/dx-streaming-upload/docker-tests/test-playbook.yml -v --extra-vars "dx_token=$2"

    # start cron
    printf "\nStarting cron:\n\n"
    service cron start

    # create some files with enough size (2GB each) to trigger an upload
    printf "\nCreating test files...\n\n"
    dd if=/dev/urandom of=/genetics/A01295/${A01295}/Data/Intensities/BaseCalls/L001/C318.1/output.dat  bs=1000 count=2000000
    dd if=/dev/urandom of=/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L001/C123.1/output.dat  bs=1000 count=1000000
    dd if=/dev/urandom of=/genetics/A01303/${A01303}/Data/Intensities/BaseCalls/L002/C166.1/output.dat  bs=1000 count=1000000

    printf "\nDone! The docker container should now be running, and uploads starting for 2 test uploads.\n"
    printf "A01295 should upload successfully, and A01303 should fail due to incomplete run cycle dirs.\n"
}
printf '\nStarting test script\n'
main "$1" "$2"
