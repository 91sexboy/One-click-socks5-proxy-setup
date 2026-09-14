#!/usr/bin/env python3
"""Shared assertion reporting and ownership of self-test process resources."""

import os
import pty
import signal
import sys
import unittest

sys.dont_write_bytecode = True


class TapTestCase(unittest.TestCase):
    def check(self, label, condition):
        with self.subTest(label=label):
            self.assertTrue(condition, label)


class TapResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.passed = 0
        self.failed = 0
        self.subtest_parents = set()

    def record(self, label, successful):
        if successful:
            self.passed += 1
        else:
            self.failed += 1
        print(("ok" if successful else "not ok") + " - " + label)

    def addSubTest(self, test, subtest, error):
        super().addSubTest(test, subtest, error)
        self.subtest_parents.add(test)
        self.record(subtest.params.get("label", str(subtest)), error is None)

    def addSuccess(self, test):
        super().addSuccess(test)
        if test not in self.subtest_parents:
            self.record(test.id(), True)

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.record(test.id(), False)

    def addError(self, test, error):
        super().addError(test, error)
        self.record(test.id(), False)


def run_tests(suite):
    result = unittest.TextTestRunner(resultclass=TapResult, verbosity=0).run(suite)
    print("TESTS %d %d" % (result.passed, result.failed))
    return int(not result.wasSuccessful())


def kill_process_group(process, timeout=2):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=timeout)


class PtySession:
    def __enter__(self):
        self.master, self.slave = pty.openpty()
        return self

    def close_slave(self):
        if self.slave is not None:
            os.close(self.slave)
            self.slave = None

    def __exit__(self, *exc_info):
        try:
            self.close_slave()
        finally:
            os.close(self.master)
