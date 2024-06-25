import os
import shutil
import unittest
from unittest.mock import patch

import pytest

from files import incremental_upload as iu
from tests import TEST_DATA_DIR


class TestCheckIdenticalSamplesheets(unittest.TestCase):
    """
    Tests for incremental_upload.check_identical_samplesheets

    Function takes 2 samplesheets to check if the contents are identical
    (i.e one is a copy of the other)
    """

    def test_identical_files_returns_true(self):
        """
        Test when file contents are identical that the function returns
        True
        """
        identical = iu.check_identical_samplesheets(
            samplesheet_1=os.path.join(TEST_DATA_DIR, 'SampleSheet.csv'),
            samplesheet_2=os.path.join(TEST_DATA_DIR, 'SampleSheet_copy.csv')
        )

        assert identical, 'Identical files not correctly identified'


    def test_different_files_return_false(self):
        """
        Test when file contents differer that function returns False
        """
        identical = iu.check_identical_samplesheets(
            samplesheet_1=os.path.join(TEST_DATA_DIR, 'SampleSheet.csv'),
            samplesheet_2=os.path.join(TEST_DATA_DIR, 'SampleSheet_different.csv')
        )

        assert not identical, 'Differing files not correctly identified'


class TestFindLocalSamplesheet(unittest.TestCase):
    """
    Tests for find_local_samplesheet.

    Function finds local samplesheet(s) and returns the name of the
    selected local file and if to halt downstream analysis in the case
    of multiple non-identical samplesheets being identified.
    """
    test_run_dir = os.path.join(TEST_DATA_DIR, 'test_run_dir')

    def setUp(self):
        os.mkdir(self.test_run_dir)


    def tearDown(self):
        shutil.rmtree(self.test_run_dir, )


    @patch('files.incremental_upload.Slack')
    def test_no_samplesheet(self, mock_slack):
        """
        Test that when no samplesheet is found that we send a Slack alert
        and return local samplesheet as None and not to halt downstream
        analysis
        """
        local_samplesheet, halt_downstream = iu.find_local_samplesheet(
            run_directory=self.test_run_dir,
            run_id='test_run'
        )

        with self.subTest('Slack alert not sent'):
            assert mock_slack.call_count == 1

        with self.subTest('local samplesheet wrongly returned'):
            assert not local_samplesheet

        with self.subTest('halt downstream wrongly set'):
            assert not halt_downstream


    def test_find_one_samplesheet(self):
        """
        Test when we find one samplesheet named `SampleSheet.csv` that we
        correctly return it and halt_downstream as False
        """
        shutil.copy(
            os.path.join(TEST_DATA_DIR, 'SampleSheet.csv'),
            os.path.join(self.test_run_dir, 'SampleSheet.csv')
        )

        local_samplesheet, halt_downstream = iu.find_local_samplesheet(
            run_directory=self.test_run_dir,
            run_id='test_run'
        )

        with self.subTest('SampleSheet.csv not returned'):
            assert local_samplesheet == 'SampleSheet.csv'

        with self.subTest('halt_downstream not returned False'):
            assert not halt_downstream

    @patch(
        'files.incremental_upload.check_identical_samplesheets',
        wraps=iu.check_identical_samplesheets
    )
    def test_two_identical_samplesheets_found(self, mock_check):
        """
        Test when we find 2 differently named samplesheets with identical
        contents that we return the first and halt_downstream as False
        """
        shutil.copy(
            os.path.join(TEST_DATA_DIR, 'SampleSheet.csv'),
            os.path.join(self.test_run_dir, 'SampleSheet.csv')
        )

        shutil.copy(
            os.path.join(TEST_DATA_DIR, 'SampleSheet_copy.csv'),
            os.path.join(self.test_run_dir, 'SampleSheet_copy.csv')
        )

        local_samplesheet, halt_downstream = iu.find_local_samplesheet(
            run_directory=self.test_run_dir,
            run_id='test_run'
        )

        with self.subTest('found incorrect samplesheet'):
            assert local_samplesheet == 'SampleSheet.csv'

        with self.subTest('halt_downstream not returned False'):
            assert not halt_downstream

        with self.subTest('check_identical_samplesheets not called'):
            # check we actually call the function to compare samplesheets
            assert mock_check.call_count == 1


    @patch('files.incremental_upload.Slack')
    @patch(
        'files.incremental_upload.check_identical_samplesheets',
        wraps=iu.check_identical_samplesheets
    )
    def test_two_different_samplesheets(self, mock_check, mock_slack):
        """
        Test when we find 2 different samplesheets with different contents
        that we correctly send a Slack alert, return None for the local
        samplesheet and return halt_downstream as True
        """
        shutil.copy(
            os.path.join(TEST_DATA_DIR, 'SampleSheet.csv'),
            os.path.join(self.test_run_dir, 'SampleSheet.csv')
        )

        shutil.copy(
            os.path.join(TEST_DATA_DIR, 'SampleSheet_different.csv'),
            os.path.join(self.test_run_dir, 'SampleSheet_different.csv')
        )

        local_samplesheet, halt_downstream = iu.find_local_samplesheet(
            run_directory=self.test_run_dir,
            run_id='test_run'
        )

        with self.subTest('local samplesheet wrongly returned'):
            assert not local_samplesheet

        with self.subTest('halt downstream not correctly set'):
            assert halt_downstream

        with self.subTest('check_identical_samplesheets not called'):
            # check we actually call the function to compare samplesheets
            assert mock_check.call_count == 1

        with self.subTest('Slack alert not sent'):
            # check we would send the Slack alert
            assert mock_slack.call_count == 1
