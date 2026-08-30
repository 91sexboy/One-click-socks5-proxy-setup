#!/bin/sh
# tests/lib/stub.sh - stub executables that record their argv, for verifying that
# socks5.sh never invokes a forbidden command and never leaks a secret via argv.
#
# All stubs live under $S5_TEST_ROOT/bin. Nothing is written outside the test root.

T_TRANSCRIPT=""

# Commands socks5.sh must NEVER invoke. These are stubbed for every test file,
# not just the ones that assert about them, because an absence assertion can
# only observe what the transcript recorded: an unstubbed command leaves no
# trace, so `t_assert_never_called "no password ever set" '^passwd '` passed
# whether or not the password had been set. Worse, the invocation reached the
# real /usr/sbin/chpasswd, /usr/bin/passwd or /usr/bin/sudo on the machine
# running the suite -- so the guard against a prohibited command was also the
# thing that would have let it run.
#
# Installing them in t_stub_init is deliberate: it is the one function every
# test file calls, so no file can build a narrower stub set and silently lose
# the detector. They exit non-zero: a forbidden command should fail loudly, not
# let the caller proceed as though it had worked.
T_FORBIDDEN_CMDS='passwd chpasswd sudo doas su git make gcc cc'

# A PATH stub is not enough. busybox implements passwd, chpasswd and su as
# built-in applets and resolves those names to the applet regardless of PATH, so
# under `busybox sh` the stub was bypassed and `passwd --probe` reached the real
# applet -- the exact three names that matter most. A shell function does take
# precedence in sh, dash and busybox ash alike, so each forbidden name gets both:
# a function for this shell (where a sourced socks5.sh runs), and a PATH stub for
# child processes. A busybox-ash *child* would still prefer its applet; no test
# asserts absence across such a child, and t_forbidden_check below fails loudly
# rather than quietly if this shell's interception ever stops working.
t_forbidden_record() {
    _sfn=$1
    shift
    if [ -z "${T_TRANSCRIPT:-}" ]; then
        printf 'forbidden command %s invoked before t_stub_init\n' "$_sfn" >&2
        return 1
    fi
    printf '%s' "$_sfn" >>"$T_TRANSCRIPT"
    for _sfa in "$@"; do printf ' %s' "$_sfa" >>"$T_TRANSCRIPT"; done
    printf '\n' >>"$T_TRANSCRIPT"
    return 1
}

# Spelled out one per line rather than generated, so that no eval is needed and
# grep finds them. t_forbidden_check catches any name added to the list above
# without a shadow here.
passwd() { t_forbidden_record passwd "$@"; }
chpasswd() { t_forbidden_record chpasswd "$@"; }
sudo() { t_forbidden_record sudo "$@"; }
doas() { t_forbidden_record doas "$@"; }
su() { t_forbidden_record su "$@"; }

# The harness must prove it can see a forbidden command before any test relies on
# not seeing one. If interception fails, every "never called" assertion in the
# file would pass for the wrong reason, so this aborts instead of continuing.
t_forbidden_check() {
    for _sfc in $T_FORBIDDEN_CMDS; do
        "$_sfc" --t-stub-init-selfcheck >/dev/null 2>&1
        if ! grep -q -- "^$_sfc --t-stub-init-selfcheck\$" "$T_TRANSCRIPT"; then
            printf 't_stub_init: %s is not intercepted; "never called %s"\n' \
                "$_sfc" "$_sfc" >&2
            printf 'assertions could not fail and the real command would run.\n' >&2
            exit 1
        fi
    done
    : >"$T_TRANSCRIPT"
}

t_stub_init() {
    if [ -z "${S5_TEST_ROOT:-}" ]; then
        printf 't_stub_init: S5_TEST_ROOT unset\n' >&2
        exit 1
    fi
    mkdir -p "$S5_TEST_ROOT/bin"
    T_TRANSCRIPT="$S5_TEST_ROOT/transcript"
    : >"$T_TRANSCRIPT"
    PATH="$S5_TEST_ROOT/bin:$PATH"
    export PATH
    for _sfc in $T_FORBIDDEN_CMDS; do
        t_stub "$_sfc" 1
    done
    t_forbidden_check
}

# t_stub <name> [exit-code] [stdout-text]
# Records one transcript line per invocation: "<name> <args...>"
t_stub() {
    _name=$1
    _code=${2:-0}
    _out=${3:-}
    cat >"$S5_TEST_ROOT/bin/$_name" <<STUB_EOF
#!/bin/sh
printf '%s' "$_name" >>"$T_TRANSCRIPT"
for _a in "\$@"; do printf ' %s' "\$_a" >>"$T_TRANSCRIPT"; done
printf '\n' >>"$T_TRANSCRIPT"
if [ -n "$_out" ]; then printf '%s\n' "$_out"; fi
exit $_code
STUB_EOF
    chmod 0755 "$S5_TEST_ROOT/bin/$_name"
}

# t_stub_script <name> <body>
# For stubs needing real logic (e.g. a fake git that answers rev-parse).
t_stub_script() {
    _name=$1
    {
        printf '#!/bin/sh\n'
        printf 'printf %s "%s" >>"%s"\n' "'%s'" "$_name" "$T_TRANSCRIPT"
        printf 'for _a in "$@"; do printf " %%s" "$_a" >>"%s"; done\n' "$T_TRANSCRIPT"
        printf 'printf "\\n" >>"%s"\n' "$T_TRANSCRIPT"
    } >"$S5_TEST_ROOT/bin/$_name"
    shift
    printf '%s\n' "$*" >>"$S5_TEST_ROOT/bin/$_name"
    chmod 0755 "$S5_TEST_ROOT/bin/$_name"
}

t_transcript() {
    if [ -f "$T_TRANSCRIPT" ]; then
        cat "$T_TRANSCRIPT"
    fi
}

# t_assert_cmd_never_called <desc> <cmd> [cmd...]
#
# Absence assertion keyed on a COMMAND NAME rather than a hand-written regex.
# Prefer this over t_assert_never_called for "this command must never run":
# two independent fail-open shapes have already shipped here as passing
# assertions, and both came from the caller writing its own pattern.
#
#   1. A trailing space means "at least one argument". '^chpasswd ' does not
#      match the transcript line a zero-argument call produces, and
#      `printf 'user:pass' | chpasswd` -- credentials on stdin, no argv -- is
#      the canonical way to set a password non-interactively. The guard against
#      the most likely form of the prohibited operation could not see it.
#      t_forbidden_record writes the name, then one ' %s' per argument, so a
#      bare call records exactly "chpasswd".
#   2. `\|` is a GNU BRE extension, not POSIX. Under a conforming grep the
#      pattern matches nothing at all -- and in an *absence* assertion a pattern
#      that cannot match is an assertion that cannot fail. (The suite runs under
#      sh/dash/busybox sh, where grep is GNU grep 3.7, so this is latent rather
#      than live; the fail-open direction is why it is designed out instead of
#      waived. The mirror-image use in t_assert_called fails closed and is safe.)
#
# The match is deliberately two greps rather than one ERE: `-x -F` for the bare
# line and a plain `^` anchor for the with-arguments form. Neither depends on a
# grep extension, and POSIX leaves `$` undefined anywhere but the end of an ERE,
# so "^cmd( |$)" would have reintroduced exactly the class of bug above.
t_assert_cmd_never_called() {
    _acnd=$1
    shift
    for _acnc in "$@"; do
        if t_transcript | grep -q -- "^$_acnc " || t_transcript | grep -qxF -- "$_acnc"; then
            t_bad "$_acnd: [$_acnc] was invoked: $(t_transcript | grep -- "^$_acnc" | tr '\n' ';')"
            return 0
        fi
    done
    t_ok
}

# t_assert_never_called <desc> <pattern>
# Pattern is an ERE. For a bare command name use t_assert_cmd_never_called.
t_assert_never_called() {
    if t_transcript | grep -qE -- "$2"; then
        t_bad "$1: transcript contains forbidden [$2]"
    else
        t_ok
    fi
}

# t_assert_called <desc> <pattern>  (pattern is an ERE)
t_assert_called() {
    if t_transcript | grep -qE -- "$2"; then
        t_ok
    else
        t_bad "$1: transcript missing [$2]; got: $(t_transcript | tr '\n' ';')"
    fi
}

# t_assert_no_secret_in_argv <desc> <secret>
t_assert_no_secret_in_argv() {
    if t_transcript | grep -qF -- "$2"; then
        t_bad "$1: secret leaked into command argv"
    else
        t_ok
    fi
}
