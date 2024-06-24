import sys
import os
import tempfile
import shutil
import unittest

import pytest

from files import incremental_upload as iu
from tests import TEST_DATA_DIR


# def create_files(rtacomplete_txt, rtacomplete_xml, copycomplete_txt):
#     tmp_folder = tempfile.mkdtemp()
#     if rtacomplete_txt:
#         with open(tmp_folder + "/RTAComplete.txt", 'w') as RTAComplete_txt:
#             RTAComplete_txt.write("foo")
#     if rtacomplete_xml:
#         with open(tmp_folder + "/RTAComplete.xml", 'w') as RTAComplete_xml:
#             RTAComplete_xml.write("bar")
#     if copycomplete_txt:
#         with open(tmp_folder + "/CopyComplete.txt", 'w') as CopyComplete_txt:
#             CopyComplete_txt.write("foobar")
#     return tmp_folder


# # parametrized with ((RTAComplete.txt, RTAComplete.xml, CopyComplete.txt), result, result_novaseq)
# @pytest.mark.parametrize("permutation,result,result_novaseq", [((False, False, False), False, False), ((False, False, True), False, True),
#                                                                ((False, True, False), True, False), ((False, True, True), True, True),
#                                                                ((True, False, False), True, False), ((True, False, True), True, True),
#                                                                ((True, True, False), True, False), ((True, True, True), True, True)])
# def test_termination_file_exists(permutation, result, result_novaseq):
#     run_dir = create_files(*permutation)
#     actual = iu.termination_file_exists(False, run_dir)
#     actual_novaseq = iu.termination_file_exists(True, run_dir)
#     shutil.rmtree(run_dir)  # deleting before potential assert failure
#     assert actual == result
#     assert actual_novaseq == result_novaseq



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
