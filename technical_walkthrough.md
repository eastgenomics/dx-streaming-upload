# dx-streaming-upload: Technical Walkthrough

*2026-03-03T07:53:02Z by Showboat 0.6.1*
<!-- showboat-id: 0cf60b4c-1e36-45c9-8964-deb14c604452 -->

## Overview

dx-streaming-upload is an Ansible role that automates the incremental upload of Illumina sequencing RUN directories to the [DNAnexus](https://dnanexus.com) cloud genomics platform. It is designed to run continuously on a sequencer-adjacent machine, streaming data to DNAnexus as the instrument generates it — without waiting for the run to complete.

Supported instruments: MiSeq, NextSeq, HiSeq-2500, HiSeq-4000, HiSeq-X, and NovaSeq.

### What problem does it solve?

Illumina sequencers can run for 24–72 hours and generate hundreds of gigabytes of BCL data. Waiting for the run to finish before uploading introduces unnecessary delay between sequencing and downstream analysis (e.g., demultiplexing). dx-streaming-upload solves this by batching files into gzipped tarballs and uploading them in rolling chunks throughout the run, then triggering a downstream applet or workflow the moment the run completes.

## Repository Layout

<details>
<summary>Full directory tree</summary>

```bash
find . -not -path './.git*' | sort | sed 's|[^/]*/|  |g'
```

```output
.
  .claude
    settings.local.json
  cron
    crontab
  defaults
    main.yml
  Dockerfile
  .dockerignore
  docker-tests
    data
      A01295
        .keep
      A01295_tmp
        .keep
      A01303
        .keep
      A01303_tmp
        .keep
      A01810
        .keep
      A01810_tmp
        .keep
    docker_test.sh
    docker_test_w_app.sh
    test_files
      eggd_conductor_upload_test.json
      RunInfo.xml
      test-playbook-template_w_app.yml
      test-playbook-template.yml
      test_samplesheet.csv
  files
    dx_sync_directory.py
    incremental_upload.py
    monitor_runs.py
    notify.py
  handlers
    main.yml
  meta
    main.yml
  README.md
  requirements.txt
  tasks
    main.yml
  technical_walkthrough.md
  templates
    monitor_run_config.template
  tests
    __init__.py
    manual_tests.md
    test_data
      SampleSheet_copy.csv
      SampleSheet.csv
      SampleSheet_different.csv
    test_incremental_upload.py
    test_monitor_runs.py
    test.yml
  .travis.yml
  vars
    main.yml
```

</details>

The repo is structured as a standard Ansible role. The active logic lives entirely in `files/` (four Python scripts) and `templates/` (one YAML config template). Ansible tasks in `tasks/main.yml` install dependencies, configure each monitored user, and wire everything together with a cron job.

## Architecture: Three-Layer Upload Pipeline

The upload process is divided into three nested layers, each implemented as an independent Python script. This layering keeps concerns separate and allows each layer to be re-triggered independently if it fails.

```
Cron (every hour / every minute in debug mode)
  └─► monitor_runs.py          Layer 1 — run discovery & triage
        └─► incremental_upload.py  Layer 2 — per-run lifecycle management
              └─► dx_sync_directory.py  Layer 3 — file batching & upload
```

| Layer | Script | Responsibility |
|-------|--------|----------------|
| 1 | `monitor_runs.py` | Scan monitored dirs, classify runs (new / in-progress / stale / done), dispatch uploads |
| 2 | `incremental_upload.py` | Manage a single run end-to-end: sentinel record, sync loop, post-upload actions |
| 3 | `dx_sync_directory.py` | Bundle modified files into gzipped tarballs and push to DNAnexus |

## Layer 1 — `monitor_runs.py`

This is the entry point, invoked by cron. It reads a YAML config, authenticates to DNAnexus via `dxpy`, scans a local directory for candidate run folders, and decides which ones need to be uploaded or re-uploaded.

<details>
<summary>monitor_runs.py --help</summary>

```bash
/tmp/dx-env/bin/python files/monitor_runs.py --help 2>&1
```

```output
usage: monitor_runs.py [-h] --config CONFIG --project PROJECT --directory
                       DIRECTORY [--verbose] [--sequencer_id SEQUENCER_ID]
                       [--script SCRIPT] [--downstream-input DOWNSTREAM_INPUT]
                       [--applet APPLET | --workflow WORKFLOW]

Script to monitor a local directory for new Illumina sequencing RUNS and
trigger the incremental upload script when a new RUN directory not net synced
to the DNANexus platform is observed.
It also re-triggers incremental upload if local log file has not been updated
for extended period of time.
This script is intended to be triggered regularly (e.g. as a CRON job)

options:
  -h, --help            show this help message and exit
  --applet APPLET, -A APPLET
                        ID of DNAnexus app(let) to execute after successful upload of the RUN folder, see incremental_upload.py. Mutually exclusive with --workflow.
  --workflow WORKFLOW, -w WORKFLOW
                        ID of DNAnexus workflow to execute after successful upload of the RUN folder, see incremental_upload.py Mutually exclusive with --applet

Required named arguments:
  --config CONFIG, -c CONFIG
                        Path to config YAML file
  --project PROJECT, -p PROJECT
                        DNAnexus project ID to upload to
  --directory DIRECTORY, -d DIRECTORY
                        Local directory to monitor for new RUN folder(s)
  --verbose, -v         Print verbose debugging messages
  --sequencer_id SEQUENCER_ID
                        ID of sequencer defined in config, used to keep log and lock file unique, and for adding to Slack notifications to know which sequencer has an issue if multiple are set up

Optional named arguemnts:
  --script SCRIPT, -s SCRIPT
                        Script to execute after successful upload of the RUN folder, see incremental_upload.py
  --downstream-input DOWNSTREAM_INPUT, -N DOWNSTREAM_INPUT
                        Input for DNAnexus applet/workflow, specified as a JSON string
```

</details>

### Run Classification Logic

`monitor_runs.py` classifies every subdirectory in the monitored folder into one of five buckets:

| Category | Criteria | Action |
|----------|----------|--------|
| **Not a run** | No `RunInfo.xml` in root | Ignored |
| **Completed syncable** | Has `RunInfo.xml` + termination file, not stale | Upload |
| **In-progress** | Has `RunInfo.xml`, no termination file, not stale | Upload (partial) |
| **Completed old** | Termination file present, older than `n_seq_intervals × run_length` | Skip |
| **Stale** | No termination file, older than `n_seq_intervals × run_length` | Skip (likely aborted) |

Termination files signal sequencing completion:
- Standard instruments: `RTAComplete.txt` or `RTAComplete.xml`
- NovaSeq: `CopyComplete.txt`

After classifying local folders, the script queries the DNAnexus project to find which runs already have a remote folder. Runs with a remote folder but an **open** (not closed) sentinel record and a stale local log are re-queued — this is the auto-recovery mechanism for interrupted uploads.

## Layer 2 — `incremental_upload.py`

This script manages the full lifecycle of uploading a single RUN directory. It is called by `monitor_runs.py` (one process per run folder, via a multiprocessing pool) and runs until the run is completely uploaded.

<details>
<summary>incremental_upload.py --help</summary>

```bash
/tmp/dx-env/bin/python files/incremental_upload.py --help 2>&1
```

```output
usage: incremental_upload.py [-h] -a <token> -p <project id> -r <path> -t
                             <path> -L <path> [-l <2 or 8>] [-m <seconds>]
                             [-z <MB>] [-M <MB>] [-i <seconds>]
                             [-D <duration>] [-I <int>] [-U] [-u <int>]
                             [-R <int>] [-s <filepath>] [-N <JSON string>]
                             [-S] [-x [<regex> ...]] [-n]
                             [--sequencer_id SEQUENCER_ID]
                             [--dxpy-upload | --verbose]
                             [-A <applet-id> | -w <workflow-id>]

Script to incrementally upload an Illumina run directory (HiSeq 2500, HiSeq X,
NextSeq, MiSeq). This script can be run at any point in the instrument run.
For more information, please see the README.md file.

options:
  -h, --help            show this help message and exit
  -a <token>, --api-token <token>
                        API token to authenticate against DNAnexus platform.
  -p <project id>, --project <project id>
                        Project ID of project to upload run directory to
  -r <path>, --run-dir <path>
                        Local path to run directory.
  -t <path>, --temp-dir <path>
                        Local path to directory where temporary TAR archives
                        will be created and stored
  -L <path>, --log-dir <path>
                        Local path to directory where incremental upload logs
                        will be stored.
  -l <2 or 8>, --num-lanes <2 or 8>
                        Upload BCL files sorted by lane. Use this option if
                        you plan to run BCL conversion parallelized by lane.
                        Not applicable to single lane machines.
  -m <seconds>, --min-age <seconds>
                        Minimum age (in seconds) of files to be tarred and
                        uploaded.
  -z <MB>, --min-size <MB>
                        Minimum size (in megabytes) of TAR before it will be
                        uploaded.
  -M <MB>, --max-size <MB>
                        Maximum size (in megabytes) of TAR to beuploaded
  -i <seconds>, --sync-interval <seconds>
                        Interval at which the run directory will be scanned,
                        and new files will be tarred and uploaded
  -D <duration>, --run-duration <duration>
                        Expected duration of the run, acceptable suffix:s, m,
                        h, d, w, M, y. (default 24h)
  -I <int>, --intervals-to-wait <int>
                        Number of --run-duration intervals to wait for run to
                        be complete. (default 3)
  -U, --upload-thumbnails
                        Flag to specify uploaded thumbnail (JPEG) files as
                        well as BCL files
  -u <int>, --upload-threads <int>
                        Number of upload threads in Upload Agent (decrease
                        down to 1 for low bandwidth connections, default 8)
  -R <int>, --retries <int>
                        Number of times the script will attempt to tar and
                        upload a set of files before failing.
  -s <filepath>, --script <filepath>
                        Path to a executable script that should be run
                        (locally) after success upload. A single command line
                        argument (corresponding to the path of the RUN
                        directory will be passed to the executable. Note:
                        script will be run after the applet has been executed.
  -N <JSON string>, --downstream-input <JSON string>
                        A JSON string specifying downstream inputs / settings
                        for the DNAnexus applet or workflow run after
                        successful upload. Note that the input
                        upload_sentinel_record for applet or
                        0.upload_sentinel_record will be overwritten
                        programmatically, even if provided by user.
  -S, --samplesheet-delay
                        Delay samplesheet upload until run data is uploaded.
  -x [<regex> ...], --exclude-patterns [<regex> ...]
                        An optional list of regex patterns to exclude.
  -n, --novaseq         If Novaseq is used, this parameter has to be used.
  --sequencer_id SEQUENCER_ID
                        ID of sequencer defined in config, used to keep log
                        and lock file unique, and for adding to Slack
                        notifications to know which sequencer has an issue if
                        multiple are set up
  --dxpy-upload, -d     This flag allows you to specify to use dxpy instead of
                        upload agent
  --verbose, -v         This flag allows you to specify upload agent --verbose
                        mode.
  -A <applet-id>, --applet <applet-id>
                        DNAnexus applet id to execute after the RUN folder has
                        been successfully uploaded (e.g. for demultiplexing).
                        A single input, -i upload_sentinel_record will be
                        passed to the applet, with the appropriate sentinel
                        record id for the uploaded run folder. Mutually
                        exclusive with --workflow.
  -w <workflow-id>, --workflow <workflow-id>
                        DNAnexus workflow id to execute after the RUN fodler
                        has been sucessfully uploaded (e.g. for
                        demux/variation calling). A single input,
                        -iupload_sentinel_record will be passed to the first
                        stage of the workflow (stage 0), with the appropriate
                        sentinel record id for uploaded run folder. Mutually
                        exclusive with --applet.
```

</details>

### Upload Sentinel Record

The script creates (or finds) a DNAnexus **record** object of type `UploadSentinel` in the remote run folder as soon as it starts. This record acts as a progress tracker:

- **open** state → upload is in progress
- **closed** state → upload is complete

`monitor_runs.py` uses the sentinel record's state to avoid re-uploading completed runs. `incremental_upload.py` also uses it as idempotency: if it finds an already-closed sentinel on startup, it exits immediately.

### The Sync Loop

While waiting for the run to complete (i.e., until the termination file appears):

1. Call `dx_sync_directory.py` (Layer 3) to bundle and upload recently-modified files.
2. Sleep for `sync_interval` seconds (default 1800 s / 30 min).
3. Repeat until `RTAComplete.txt/xml` (or `CopyComplete.txt` for NovaSeq) appears, or until the timeout `run_duration × intervals_to_wait` is exceeded.

On timeout, an error is raised and a Slack alert is sent.

### Final Upload Pass

When the termination file appears, `incremental_upload.py` calls `dx_sync_directory.py` one final time with `--finish` mode (min-age forced to 0, so every remaining file is captured), uploads the log file, sets details on the sentinel record, and closes it.

### Post-Upload Actions (in order)

1. **Cycle completeness check** — `CheckCycles` in `notify.py` reads `RunInfo.xml` to get the expected cycle count, then counts actual cycle directories under `Data/Intensities/BaseCalls/`. A mismatch triggers a Slack alert and halts downstream analysis.
2. **Downstream applet** — If `--applet` was specified, the applet is launched with the closed sentinel record as input (`upload_sentinel_record`).
3. **Downstream workflow** — If `--workflow` was specified, the workflow is launched with the sentinel record at stage 0 (`0.upload_sentinel_record`).
4. **Local script** — If `--script` was specified, the executable is called with the local run directory path as its sole argument.

## Layer 3 — `dx_sync_directory.py`

This is the lowest-level workhorse. Each invocation identifies files that have changed since the last sync, bundles them into numbered gzipped tarballs, uploads each tarball using the DNAnexus Upload Agent (`ua`) or `dxpy` (fallback), and removes the local tarball after a confirmed upload.

<details>
<summary>dx_sync_directory.py --help</summary>

```bash
/tmp/dx-env/bin/python files/dx_sync_directory.py --help 2>&1
```

```output
usage: dx_sync_directory.py [-h] [--tar-directory <directory>] --auth-token
                            <TOKEN> --tar-destination <platform-location>
                            --log-file <file> [--min-tar-size <MB>]
                            [--max-tar-size <MB>] [--upload-threads <int>]
                            [--include-patterns [<regex> ...]]
                            [--exclude-patterns [<regex> ...]] --prefix
                            <prefix> [--dxpy-upload | --verbose]
                            [--min-age <seconds> | --finish]
                            <directory>

Script to "synchronize" a local directory into the platform. This does not
transfer files into the platform one-by-one, but rather uploads gzipped tar
files containing bundles of recently modified files.

positional arguments:
  <directory>           Directory to sync.

options:
  -h, --help            show this help message and exit
  --tar-directory <directory>, -t <directory>
                        Local directory in which to write temporary tar files
                        during upload.
                        DEFAULT: /tmp

  --auth-token <TOKEN>, -a <TOKEN>
                        Authorization token to use for uploads
  --tar-destination <platform-location>, -T <platform-location>
                        Remote (platform) project-ID and folder to which to
                        upload tar files.
                        IF NOT SPECIFIED: files are uploaded to the current
                        project and folder as determined from the dx
                        environment.

  --log-file <file>, -l <file>
                        Local path to a log file describing sync state.
                        This file contains the path of each uploaded file,
                        including the modified timestamp of the file at the
                        time of upload. Previously uploaded files are ignored
                        unless either of those attributes has changed.

  --min-tar-size <MB>, -s <MB>
                        The minimum size of the tar file to be uploaded. If
                        the number of modified files does not total this
                        size, the tar file will not be created or uploaded.
                        If --finish is specified, this argument will
                        automatically be set to 0. DEFAULT=0 MB

  --max-tar-size <MB>, -X <MB>
                        The maximum size of the tar file to be uploaded. If
                        the total size of the files to be uploaded is
                        greater, the files will be split into multiple
                        archives. --max-tar-size must be greater than
                        --min-tar-size. DEFAULT=75 MB

  --upload-threads <int>, -u <int>
                        Number of upload threads launched by Upload Agent
                        (Decrease to improve stability in low-bandwidth
                        connections), DEFAULT=8]n
  --include-patterns [<regex> ...], -i [<regex> ...]
                        An optional list of regex patterns to search for.
                        If 1 or more regex patterns are given, then
                        only the files matching the pattern will be tarred
                        and uploaded. The pattern will be matched against
                        the full file path. (i.e. "/foo" will match all the
                        files and subdirectories under  a directory named foo/
                        and the file foo.txt)

  --exclude-patterns [<regex> ...], -x [<regex> ...]
                        An optional list of regex patterns to exclude.
                        If 1 or more regex patterns are given, the files
                        matching the pattern will be skipped (not tarred nor
                        uploaded). This pattern will override the
                        --include-patterns argument so if a file matches a
                        regex specified by --include-patterns AND matches a regex
                        specified here, the file will ultimately be excluded
                        from upload. The pattern will be matched against the
                        full file path.

  --prefix <prefix>, -p <prefix>
                        Required prefix string to name the TAR archives to be
                        uploaded. This prefix will be stored in the log. If the
                        log file given already exists, the prefix will be compared
                        to the one stored in the log. dx_sync_directory.py will
                        fail if the prefix does not match.

  --dxpy-upload, -d     This flag allows you to specify whether to use dxpy
                        instead of the default Upload Agent to upload your
                        data.

  --verbose, -v         This flag allows you to specify upload agent
                        --verbose mode.

  --min-age <seconds>, -m <seconds>
                        The minimum age (in seconds) of files to be synced.
                        Only files whose modified timestamp is at least
                        <seconds> seconds in the past will be synced. This is
                        a heuristic aimed at ensuring that we only upload
                        files that have finished being written. If <seconds>
                        is less than 1, the script will upload all files that
                        have not yet been uploaded, so as to finish syncing a
                        directory where files are no longer expected to be
                        created or modified.

  --finish, -f          If this flag is set, the minimum age of files to be
                        uploaded is set to zero, forcing all files not yet
                        uploaded to be uploaded. If any tar file created
                        during this or a previous run was not successfully
                        uploaded, the script exits with a non-zero status
                        code. If all tar files created during this or a
                        previous run were successfully uploaded, the file IDs
                        of the uploaded files are printed to standard output.


Each time this script is run, it examines the specified directory and the log
file (if it exists). It identifies each file that has not yet been uploaded,
and whose modified timestamp is at least <min-age> seconds in the past.,
In addition, it finds all files which have been previously uploaded, but whose
modified timestamp has changed since the previous upload.

All of the files to be uploaded are added to a gzipped TAR file which is
then uploaded. Newly uploaded files are recorded in the log file, including
the modified timestamp of each file at the time it was added to the tar file.

The platform file ID of the uploaded file is printed to standard output, and
the script exits.
```

</details>

### Log File Format

The script maintains a JSON log file that is the source of truth for what has been uploaded. Its schema:

```
{
  "sync_dir": "/path/to/run",
  "tar_destination": "project-xxx:/RUN_ID/runs",
  "file_prefix": "run.RUN_ID.lane.all",
  "include_patterns": [],
  "exclude_patterns": ["Images"],
  "next_tar_index": 3,
  "files": {
    "/path/to/run/Data/Intensities/s.locs": {"mtime": 1700000000.0}
  },
  "tar_files": {
    "/tmp/run.RUN_ID.lane.all_000.tar.gz": {
      "status": "removed",
      "size": 524288000,
      "file_id": "file-Bxxx",
      "timestamps": {"tar_start": ..., "tar_end": ..., "upload_start": ..., "upload_end": ..., "remove_start": ..., "remove_end": ...}
    }
  }
}
```

Each subsequent invocation reads this log to skip already-uploaded files (unless their mtime has changed) and resumes uploading any tarballs that were created but not yet successfully transferred.

### Tarball Naming Convention

Tarballs are named using a zero-padded sequential index:

`run.<RUN_ID>.lane.<all|1|2|…>_NNN.tar.gz`

e.g. `run.20240101_M000001_0001_000000000-ABCDE.lane.all_000.tar.gz`

This naming is set by the `--prefix` argument passed from `incremental_upload.py`.

## Notification System — `notify.py`

`notify.py` provides two classes consumed by `incremental_upload.py`:

### `Slack` class

Sends messages to two configurable Slack channels via the `chat.postMessage` API, using credentials from environment variables:

| Variable | Purpose |
|----------|---------|
| `SLACK_TOKEN` | Slack app OAuth token |
| `SLACK_LOG_CHANNEL` | Channel for success/progress notifications |
| `SLACK_ALERT_CHANNEL` | Channel for error alerts |

Notifications sent during an upload lifecycle:

1. **Upload start** — sent once per run (tracked via a per-sequencer `.start_notify.log` file to prevent duplicate messages on re-trigger)
2. **Upload success** — includes run ID, experiment name, upload duration, run size, and disk usage
3. **Error alerts** — invalid API token, permission errors, XML parse failures, upload timeouts, incomplete cycles, multiple samplesheets

The HTTP client uses `urllib3` with 5 retries and exponential backoff (factor 10s) for resilience against transient Slack API failures.

### `CheckCycles` class

Post-upload sanity check that catches a class of sequencer failures invisible to the upload process itself:

1. Reads `RunInfo.xml` and sums `NumCycles` across all reads to get the expected total cycle count.
2. Scans `Data/Intensities/BaseCalls/L00N/` directories for cycle directories matching `C\d+\.\d`.
3. Compares the maximum cycle directory index per lane against the expected total.
4. If any lane is short, returns an error message; the caller uploads an alert file to DNAnexus and aborts downstream analysis.

## Configuration

### YAML Config Template (`templates/monitor_run_config.template`)

Each monitored user/sequencer gets its own config file, templated from `monitor_run_config.template` and placed at `~/dnanexus/config/<sequencer_id>_monitor_runs.config`.

<details>
<summary>monitor_run_config.template</summary>

```bash
cat templates/monitor_run_config.template
```

```output
# Local directory for log file
# Corresponds to -L parameter in incremental upload
log_dir: '~/dnanexus/upload/LOGS'

# Local directory for temp files
# Corresponds to -t parameter in incremental upload
tmp_dir: '~/dnanexus/upload/TMP'

# Exclude pattern for excluding files or directories
# Corresponds to -x parameter in incremental upload and dx sync directory
exclude: ''

# Number of times to retry dx_sync_directory before quitting
# default = 3; corresponds to -R parameter in incremental upload
n_retries: 3

# Expected duration of a sequencing run.
# Corresponds to -D paramter in incremental upload
# Acceptable suffix: s, m, h, d, w, M, y
run_length: 24h

# Number of intervals to wait for run to complete. If
# the sequencing run has not completed within
# n_seq_intervals * run_length, it will be deemed as aborted
# and the program will not attempt to upload it
# Correspond to the -I parameter in incremental upload
n_seq_intervals: 2

# Number of upload threads executed by Upload Agent (UA)
# This number should be reduced (to as low as 1) for upload
# sites with low upload bandwidth to increase chance
# of successful uploads in spite of network disruptions
# Corresponds to the -u option in UA and incremental_upload.py
n_upload_threads: 8

# the minimum size needed to upload a chunk (in MB)
min_size: 500

# the maximum size of the tarball (in MB)
max_size: 10000

# min sync check interval (in seconds)
min_interval: 900

# number of concurrent uploads
n_streaming_threads: 1

# Delay Sample Sheet upload
delay_sample_sheet_upload: False

# Novaseq flag
novaseq: False
```

</details>

### Key Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `log_dir` | `~/dnanexus/upload/LOGS` | Persistent log directory (per-run JSON logs) |
| `tmp_dir` | `~/dnanexus/upload/TMP` | Transient tarball staging area |
| `run_length` | `24h` | Expected sequencing duration |
| `n_seq_intervals` | `2` | Multiplier: run is stale after `run_length × n_seq_intervals` |
| `min_size` | `500` MB | Don't upload a tarball smaller than this (mid-run only) |
| `max_size` | `10000` MB | Split tarballs larger than this |
| `min_interval` | `900` s | Minimum gap between sync passes |
| `n_upload_threads` | `8` | UA upload concurrency (reduce to 1 on low-bandwidth links) |
| `n_streaming_threads` | `1` | Concurrent run uploads from one monitored directory |
| `novaseq` | `False` | Use `CopyComplete.txt` instead of `RTAComplete.txt/xml` |
| `delay_sample_sheet_upload` | `False` | Upload samplesheet after run data (for mid-run edits) |

## Ansible Role Setup

The Ansible role (`tasks/main.yml`) performs the following actions in order:

1. **Install dx-toolkit** — runs `pip install -r requirements.txt` on the remote machine (Python packages: `dxpy`, `pyyaml`, `beautifulsoup4`, `lxml`, `requests`, `urllib3`).
2. **Install Upload Agent** — downloads the `ua` binary tarball from DNAnexus S3 and places it at `/opt/dnanexus-upload-agent/`.
3. **Login to DNAnexus** — runs `dx login --token <token>` as each monitored user; the login environment is persisted to disk.
4. **Deploy scripts** — copies the four Python scripts from `files/` to `/opt/dnanexus/scripts/`.
5. **Write per-user config** — copies `monitor_run_config.template` to `~/dnanexus/config/<sequencer_id>_monitor_runs.config` for each monitored user, then patches it line-by-line with Ansible `lineinfile` for each optional parameter that is set.
6. **Create lock file** — touches `/var/lock/dnanexus_uploader_<sequencer_id>.lock` so `flock` can prevent overlapping cron invocations.
7. **Install cron job** — installs either a per-minute (debug) or hourly (deploy) cron entry for each `monitored_user × monitored_directory` combination using `flock -w 5` for mutual exclusion.

### Generated Cron Entry (deploy mode)

The cron entry wraps the entire command in `flock` to ensure only one instance runs at a time per sequencer, and redirects all output to per-sequencer log files:

```
# Every hour (deploy mode)
@hourly flock -w 5 /var/lock/dnanexus_uploader_<SEQ_ID>.lock bash -ex -c '
  SLACK_TOKEN=$SLACK_TOKEN;
  SLACK_LOG_CHANNEL=$SLACK_LOG_CHANNEL;
  SLACK_ALERT_CHANNEL=$SLACK_ALERT_CHANNEL;
  PATH=/opt/dnanexus-upload-agent:$PATH;
  python3 /opt/dnanexus/scripts/monitor_runs.py \
    -c ~/dnanexus/config/<SEQ_ID>_monitor_runs.config \
    -p <project-id> \
    --sequencer_id <SEQ_ID> \
    -d <monitored_dir> \
    [-A <applet-id> | -w <workflow-id>] \
    [-s <script>] \
    -v > ~/monitor_<SEQ_ID>.log 2>&1
' > ~/dx-stream_cron_<SEQ_ID>.log 2>&1
```

In **debug mode** the cron fires every minute (`* * * * *`) and omits the Slack environment variable forwarding.

## DNAnexus Output Structure

For a run named `20160101_M000001_0001_000000000-ABCDE` uploaded to `project-xxx`:

```bash
cat <<'EOF'
project-xxx/
└── 20160101_M000001_0001_000000000-ABCDE/
    ├── runs/
    │   ├── RunInfo.xml
    │   ├── SampleSheet.csv
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all.log
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all.upload_sentinel  [record]
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all_000.tar.gz
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all_001.tar.gz
    │   └── ...
    ├── reads/          (only if applet was triggered)
    │   └── <demux output files>
    └── analyses/       (only if workflow was triggered)
        └── <analysis output files>
EOF
```

```output
project-xxx/
└── 20160101_M000001_0001_000000000-ABCDE/
    ├── runs/
    │   ├── RunInfo.xml
    │   ├── SampleSheet.csv
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all.log
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all.upload_sentinel  [record]
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all_000.tar.gz
    │   ├── run.20160101_M000001_0001_000000000-ABCDE.lane.all_001.tar.gz
    │   └── ...
    ├── reads/          (only if applet was triggered)
    │   └── <demux output files>
    └── analyses/       (only if workflow was triggered)
        └── <analysis output files>
```

## Docker Packaging

A `Dockerfile` based on Ubuntu 20.04 packages the role for environments where Ansible is not installed. Key details:

- Base image: `ubuntu:20.04`
- Installs Ansible, cron, Python 3 + pip, and project requirements.
- Comments out the `pip install` step in `tasks/main.yml` so it doesn't re-run inside the container (packages are pre-installed at image build time).
- Creates a monitor log backup directory at `/var/log/dx-streaming-upload/monitor_log_backups/`.
- Installs a crontab that backs up `monitor*.log` files hourly (via `savelog`) with a 72-hour rolling retention — this guards against `monitor.log` being overwritten on cron restart and losing debugging information.
- Entrypoint: `service cron start; printenv >> /etc/environment; /bin/bash` — starts cron, exports current env vars to `/etc/environment` so cron jobs inherit Slack credentials, then drops to a shell.

### Docker run command skeleton

```bash
docker build -t dx-streaming-upload:v1.0.0 .

docker run -itd \
  --name dx-streaming-upload \
  --user dx-upload \
  -v /genetics:/genetics \
  -v /playbooks:/playbooks \
  -v /var/logs/dx-streaming-upload/:/var/log/dx-streaming-upload/ \
  -e SLACK_TOKEN="{token}" \
  -e SLACK_LOG_CHANNEL="{log_channel}" \
  -e SLACK_ALERT_CHANNEL="{alert_channel}" \
  dx-streaming-upload:v1.0.0

# Then run Ansible inside the container:
docker exec -it {container-id} bash -c \
  "ansible-playbook /playbooks/dx-upload-play.yml -i inventory --extra-vars 'dx_token=<SECRET_TOKEN>'"
```

## Samplesheet Handling

`incremental_upload.py` performs careful samplesheet management:

1. **Discovery** — searches the run directory for files matching the regex `.*sample[-_ ]?sheet.*.csv$` (case-insensitive).
2. **Zero found** — Slack alert sent, but upload continues (downstream analysis still runs).
3. **Exactly one found** — that samplesheet is used.
4. **Two found, identical** — MD5 hash comparison; if identical, the first is used.
5. **Two found, different** or **three or more found** — Slack alert sent, upload continues, but downstream analysis is **halted** (no applet/workflow triggered).

The samplesheet can optionally be uploaded **after** the run data (`delay_sample_sheet_upload: True`) for sites that modify it during sequencing.

The script also extracts the `Experiment Name` field from the samplesheet CSV and includes it in Slack notifications and the DNAnexus job name.

## Logging

| Log file | Location | Contents |
|----------|----------|---------|
| `~/dx-stream_cron_<SEQ_ID>.log` | Monitored user home dir | Top-level cron output (bash -ex trace) |
| `~/monitor_<SEQ_ID>.log` | Monitored user home dir | Verbose output from `monitor_runs.py` and `incremental_upload.py` |
| `~/<SEQ_ID>_all_runs_state.log` | Monitored user home dir | Per-check snapshot of how each detected run folder was classified |
| `<log_dir>/run.<RUN_ID>.lane.<N>.log` | Configurable log dir | JSON sync-state log maintained by `dx_sync_directory.py`; also uploaded to DNAnexus |
| `~/monitor_log_backups/` (Docker) | `/var/log/dx-streaming-upload/` | Hourly timestamped copies of `monitor*.log` kept for 72 h |

## Error Recovery

The system is designed to be re-triggered safely:

- **Cron-level**: `flock` prevents overlapping invocations of the same sequencer's monitor job.
- **Run-level**: If a run appears in DNAnexus with an open (not closed) sentinel record AND the local log file has not been updated for `N_INTERVALS_TO_WAIT × min_interval` seconds (default: 5 × 1800 s = 2.5 h), the upload is considered stalled and is re-triggered on the next cron tick.
- **Tarball-level**: `dx_sync_directory.py` tracks each tarball through states (`tarred → uploaded → removed`). If a previous run created a tarball but crashed before uploading, the next invocation will upload it before creating any new tarballs.
- **Retry**: `run_command_with_retry` wraps `dx_sync_directory.py` calls with up to `n_retries` attempts (default 3), with a 10-second sleep between tries.

## Dependencies

| Package | Version (pinned) | Role |
|---------|-----------------|------|
| `dxpy` | 0.398.0 | DNAnexus Python SDK — API calls, file upload, record management |
| `pyyaml` | 6.0.2 | Parsing the per-user YAML config file |
| `beautifulsoup4` | 4.13.5 | XML parsing of `RunInfo.xml` in `CheckCycles` |
| `lxml` | 6.0.1 | XML parser backend for BeautifulSoup |
| `requests` | 2.32.4 | HTTP client for Slack API |
| `urllib3` | 2.2.3 | Retry adapter for `requests` |

The DNAnexus Upload Agent (`ua`) binary is also required and installed separately via the Ansible role.

## Test Suite

```
tests/
├── test_monitor_runs.py      # Unit tests for run classification, config parsing, DNAnexus queries
├── test_incremental_upload.py # Unit tests for samplesheet handling, cycle checking
├── test_data/                # Fixture samplesheets (identical pair and divergent pair)
└── manual_tests.md           # Instructions for end-to-end manual testing
```

Docker integration tests (`docker-tests/docker_test.sh`) simulate four concurrent sequencer scenarios:
- `A01295` — successful upload with success Slack notification
- `A01303` — missing cycle directories → alert sent
- `A01625` — two identical samplesheets → upload succeeds
- `A01810` — two different samplesheets → alert sent, no downstream analysis

```bash
wc -l files/*.py
```

```output
  574 files/dx_sync_directory.py
  961 files/incremental_upload.py
  589 files/monitor_runs.py
  192 files/notify.py
 2316 total
```

The four Python scripts total 2316 lines of code. All logic is in pure Python 3 with no compiled extensions beyond the dependencies listed above.
