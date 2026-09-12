#!/bin/sh
# Fixtures shared by the two lifecycle gates (systemd-lifecycle.sh and
# alpine-lifecycle.sh). Only the answer/credential content is identical on both
# backends; how each gate drives the installer and inspects the service differs
# and stays in each script. Sourced, not executed.
#
# lifecycle_write_fixtures <workdir>: write the install and in-place-update answer
# and password files into <workdir> and lock them to 0600. The in-place update
# rotates to ciuser2/CISecret_456~y on the same port, which each gate then asserts
# landed in the config and the state.
lifecycle_write_fixtures() {
    _lcw=$1
    printf '2\ny\n23456\nciuser\nCISecret_123~x\n' >"$_lcw/answers"
    printf 'ciuser\nCISecret_123~x\n' >"$_lcw/pass"
    printf 'y\n23456\nciuser2\nCISecret_456~y\n' >"$_lcw/answers.update"
    printf 'ciuser2\nCISecret_456~y\n' >"$_lcw/pass.update"
    chmod 0600 "$_lcw/answers" "$_lcw/pass" "$_lcw/answers.update" "$_lcw/pass.update"
}
