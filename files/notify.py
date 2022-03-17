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
import json
import dxpy as dx
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


    def send(self, message):
        """
        Send notification to Slack

        Parameters
        ----------
        message : str
            message to send to Slack
        """
        message = f"Error in dx-streaming-upload:\n\n{message}"
        http = requests.Session()
        retries = Retry(total=5, backoff_factor=10, method_whitelist=['POST'])
        http.mount("https://", HTTPAdapter(max_retries=retries))

        response = http.post(
            'https://slack.com/api/chat.postMessage', {
                'token': self.slack_token,
                'channel': f'#{self.slack_channel}',
                'text': message
            }).json()


class checkCycles():
    """
    dx-streaming-upload can appear to have uploaded everything fine, but
    issues with the sequencer can cause cycles to not complete and an
    incomplete run uploaded. The total no. reads can be read from {file} and
    we can check this against the total cycles files written to disk.
    """
    def __init__(self, run_dir) -> None:
        self.run_dir = run_dir


    def check(self) -> None:
        """
        Call funcions to check logs
        """
        self.read_runinfo_xml()


    def read_runinfo_xml(self):
        """
        Reads NumCycles from RunInfo.xml to get total expected cycles

        Returns
        -------
        cycle_counts : int
        """
        runinfo = os.path.join(self.run_dir, "RunInfo.xml")

        with open(runinfo) as fh:
            contents = fh.read()

        bs_data = bs(contents, 'xml')
        reads = bs_data.find_all('Read')
        cycle_counts = sum([
            int(x.get('NumCycles')) for x in reads.find_all('Read')
        ])

        return cycle_counts
