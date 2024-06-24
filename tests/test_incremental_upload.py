import os
import unittest

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
