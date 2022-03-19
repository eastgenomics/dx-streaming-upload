"""
Called from incremental_upload.py to run whilst an upload is in progress.
Handles notifying of any errors raised by dx-streaming-upload to a given
Slack channel

Jethro Rainford
220316
"""
import os
import sys
import requests
from requests.adapters import HTTPAdapter
from urllib3.util import Retry

from bs4 import BeautifulSoup as bs


class slack():
    """
    Slack related functions
    """
    def __init__(self) -> None:
        self.slack_token = os.getenv("SLACK_TOKEN")
        self.slack_channel = os.getenv("SLACK_CHANNEL")


    def send(self, message, run):
        """
        Send notification to Slack

        Parameters
        ----------
        message : str
            message to send to Slack
        run : str
            sequencing run to send notification for
        """
        message = (
            f":warning: *Error in dx-streaming-upload:*\n\n"
            f"Run: {run}\n\n{message}"
        )
        http = requests.Session()
        retries = Retry(total=5, backoff_factor=10, method_whitelist=['POST'])
        http.mount("https://", HTTPAdapter(max_retries=retries))

        response = http.post(
            'https://slack.com/api/chat.postMessage', {
                'token': self.slack_token,
                'channel': self.slack_channel,
                'text': message
            }).json()


class checkCycles():
    """
    dx-streaming-upload can appear to have uploaded everything fine, but
    issues with the sequencer can cause cycles to not complete and an
    incomplete run uploaded. The total no. cycles can be read from RunInfo.xml
    and we can check this against the total cycle dirs written to disk.
    """
    def __init__(self, run_dir) -> None:
        self.run_dir = run_dir
        self.cycle_dir = "Data/Intensities/BaseCalls/"


    def check(self) -> None:
        """
        Call funcions to check logs
        """
        cycle_count = self.read_runinfo_xml()
        lanes, max_cycles = self.find_cycle_dirs()

        completed = all([x == cycle_count for x in max_cycles])

        if not completed:
            # at least one lane not completed all cycles
            message = f"\n\t".join([
                f"\t\t\t\t\t\t{x}\t:\t{y}" for x, y in zip(lanes, max_cycles)
            ])
            message = (
                f"Total sequencing cycles do not appear to have completed.\n"
                f"Expected cycles: *{cycle_count}*\n\n"
                f"Cycles found:"
                f"\tLane\t\tCycles\n\n\t{message}"
            )
            slack().send(message=message, run=self.run_dir)


    def read_runinfo_xml(self):
        """
        Reads NumCycles from RunInfo.xml to get total expected cycles

        Returns
        -------
        cycle_count : int
            total cycles expected to run on sequencer
        """
        runinfo = os.path.join(self.run_dir, "RunInfo.xml")

        with open(runinfo) as fh:
            contents = fh.read()

        bs_data = bs(contents, 'xml')
        reads = bs_data.find_all('Read')
        cycle_count = sum([int(x.get('NumCycles')) for x in reads])

        return cycle_count


    def find_cycle_dirs(self):
        """
        Search the expected cycle dir and check for highest dir written.
        There should be one dir per cycle, so the highest should match the
        cycle count in RunInfo.xml

        Returns
        -------
        lanes : list
            list of lanes for given run (i.e [L001, L002...])
        max_cycles : list
            list of integers of max cycle dir per lane
        """
        cycle_path = os.path.join(self.run_dir, self.cycle_dir)
        lanes = sorted(os.listdir(cycle_path))

        lane_dirs = [os.listdir(os.path.join(cycle_path, x)) for x in lanes]

        max_cycles = [sorted(x)[-1] for x in lane_dirs]  # get highest cycle
        max_cycles = [
            int(x.replace('C', '').replace('.1', '')) for x in max_cycles
        ]

        return lanes, max_cycles
