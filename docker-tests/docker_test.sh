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
        printf "\nscript must be run as bash /home/dx-upload/dx-streaming-upload/docker-tests/docker_test.sh "
        printf "{dnanexus-project-id} {dnanexus-auth-token}\n"
        printf "\n\nExiting now\n"
        exit 1
    fi

    # add slack token and proxy to /etc/environment for cron to access
    printenv | grep SLACK >> /etc/environment
    echo "HTTP_PROXY=${HTTP_PROXY}" >> /etc/environment
    echo "HTTPS_PROXY=${HTTP_PROXY}" >> /etc/environment
    echo "http_proxy=${http_proxy}" >> /etc/environment
    echo "https_proxy=${http_proxy}" >> /etc/environment


    A01295_1="A01295_${RANDOM}_1_test_upload"
    A01303_1="A01303_${RANDOM}_1_test_upload"
    A01625_1="A01625_${RANDOM}_1_test_upload"

    printf "\nCreating test runs:\n\t\t\t${A01295_1}\n\t\t\t${A01303_1}\n\t\t\t${A01625_1}\n"

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    printf "\nCreating example directory structure...\n"
    mkdir -p /home/dx-upload/test_runs/A01295/${A01295_1}/Data/Intensities/BaseCalls/L001/C318.1
    mkdir -p /home/dx-upload/test_runs/A01303/${A01303_1}/Data/Intensities/BaseCalls/L001/C123.1
    mkdir -p /home/dx-upload/test_runs/A01303/${A01303_1}/Data/Intensities/BaseCalls/L002/C166.1
    mkdir -p /home/dx-upload/test_runs/A01625/${A01625_1}/Data/Intensities/BaseCalls/L001/C318.1


    # create malformed and duplicate samplesheet names to test regex matching and uploading
    # add experiment name to A01295 and A01303 that will upload to test parsing out for
    # sending in Slack notification
    echo "Experiment Name: experiment_name_from_samplesheet_A01295" > \
        /home/dx-upload/test_runs/A01295/${A01295_1}/samplesheet_for_run_A01295_${A01295_1}.csv
    echo "Experiment Name: experiment_name_from_samplesheet_A01303" > \
        /home/dx-upload/test_runs/A01303/${A01303_1}/SampleSheet.csv
    touch /home/dx-upload/test_runs/A01625/${A01625_1}/SampleSheet.csv \
        /home/dx-upload/test_runs/A01625/${A01625_1}/SampleSheetDuplicate.csv


    # create RunInfo.xml files with IDs added
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01295_1}\">/g" \
        > /home/dx-upload/test_runs/A01295/${A01295_1}/RunInfo.xml
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01303_1}\">/g" \
        > /home/dx-upload/test_runs/A01303/${A01303_1}/RunInfo.xml
    cat /home/dx-upload/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01625_1}\">/g" \
        > /home/dx-upload/test_runs/A01625/${A01625_1}/RunInfo.xml

    # trigger Ansible
    printf "\n\nStarting dx-streaming-upload\n\n"
    ansible-playbook /home/dx-upload/dx-streaming-upload/docker-tests/test-playbook.yml -v --extra-vars "dx_token=$2"

    # start cron
    printf "\nStarting cron:\n\n"
    service cron start

    # create some files with enough size (2GB each) to trigger an upload
    printf "\nCreating test files...\n\n"
    dd if=/dev/urandom of=/home/dx-upload/test_runs/A01295/${A01295_1}/Data/Intensities/BaseCalls/L001/C318.1/output.dat bs=500 count=1000000
    dd if=/dev/urandom of=/home/dx-upload/test_runs/A01303/${A01303_1}/Data/Intensities/BaseCalls/L001/C123.1/output.dat bs=500 count=1000000
    dd if=/dev/urandom of=/home/dx-upload/test_runs/A01625/${A01625_1}/Data/Intensities/BaseCalls/L001/C318.1/output.dat bs=500 count=1000000

    # create CopyComplete.txt so the runs are flagged as complete and will upload and close
    touch /home/dx-upload/test_runs/A01295/${A01295_1}/CopyComplete.txt \
          /home/dx-upload/test_runs/A01303/${A01303_1}/CopyComplete.txt \
          /home/dx-upload/test_runs/A01625/${A01625_1}/CopyComplete.txt


    printf "\nDone! The docker container should now be running, and uploads starting for 3 test uploads.\n\n"
    printf "\t\tA01295 should upload successfully\n"
    printf "\t\tA01303 should upload and send an alert due to incomplete run cycle dirs\n"
    printf "\t\tA01625 should upload and send an alert for more than one samplesheet\n\n"
}
printf '\nStarting test script\n'
main "$1" "$2"
