#! /bin/bash
# Script to run in the built docker image to test dx-streaming-upload and running of a downstream
# app (eggd_conductor)

# $1 -> project-id to upload to
# $2 -> dx-token

set -e

main() {

    if [[ -z $2 ]]; then
        printf "\ndx project and/or token not provided\n"
        printf "\nscript must be run as bash /root/dx-streaming-upload/docker-tests/docker_test.sh "
        printf "{dnanexus-project-id} {dnanexus-auth-token}\n"
        printf "\n\nExiting now\n"
        exit 1
    fi

    dx login --auth-token $2 --noprojects

    # add passed project id to playbook
    cat /root/dx-streaming-upload/docker-tests/test_files/test-playbook-template_w_app.yml | \
        sed -r "s/(upload_project:).*/\1 $1/g" > /root/test-playbook.yml

    # upload assay config file for conductor to be able to set as input in the playbook to
    # not need to do sample-assay code matching    
    config_id=$(dx upload /root/dx-streaming-upload/docker-tests/test_files/eggd_conductor_upload_test.json --project $1 --brief)
    cat /root/test-playbook.yml \
        | sed -r "s/assay-id/$config_id/g" \
        | tee /root/test-playbook.yml > /dev/null

    # add slack token and proxy to /etc/environment for cron to access
    printenv | grep SLACK >> /etc/environment
    echo "HTTP_PROXY=${HTTP_PROXY}" >> /etc/environment
    echo "HTTPS_PROXY=${HTTP_PROXY}" >> /etc/environment
    echo "http_proxy=${http_proxy}" >> /etc/environment
    echo "https_proxy=${http_proxy}" >> /etc/environment


    A01295_1="A01295_${RANDOM}_1_test_upload"

    printf "\nCreating test runs:\n\t\t\t${A01295_1}\n"

    # create cycle dirs, notify.py gets the highest in /Data/Intensities/Basecalls
    # so just create one to match
    printf "\nCreating example directory structure...\n"
    mkdir -p /root/test_runs/A01295/${A01295_1}/Data/Intensities/BaseCalls/L001/C318.1

    # copy in test samplesheet
    cp /root/dx-streaming-upload/docker-tests/test_files/test_samplesheet.csv \
        /root/test_runs/A01295/${A01295_1}/SampleSheet.csv

    # create RunInfo.xml files with IDs added
    cat /root/dx-streaming-upload/docker-tests/test_files/RunInfo.xml | sed -r "s/(Id=).*/Id=\"${A01295_1}\">/g" \
        > /root/test_runs/A01295/${A01295_1}/RunInfo.xml

    # trigger Ansible
    printf "\n\nStarting dx-streaming-upload\n\n"
    ansible-playbook /root/test-playbook.yml -v --extra-vars "dx_token=$2"

    # start cron
    printf "\nStarting cron:\n\n"
    service cron start

    # create some files with enough size (2GB each) to trigger an upload
    printf "\nCreating test files...\n\n"
    dd if=/dev/urandom of=/root/test_runs/A01295/${A01295_1}/Data/Intensities/BaseCalls/L001/C318.1/output.dat bs=500 count=100000
    
    # create CopyComplete.txt so the runs are flagged as complete and will upload and close
    touch /root/test_runs/A01295/${A01295_1}/CopyComplete.txt

    printf "\nDone! dx-streaming-upload should now be running, and upload will start, followed by running of eggd_conductor"
}

printf '\nStarting test script with app launching\n'
main "$1" "$2"
