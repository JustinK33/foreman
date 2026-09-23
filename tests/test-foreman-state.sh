#!/usr/bin/env bash
# foreman_state is the one module two hooks share, and the only one with no
# process boundary of its own, so it is driven directly rather than through a
# payload. The contracts below are the ones its callers silently depend on: the
# dedupe return value, the prefix filter, and failing open instead of raising.
#
# Shell to match the rest of tests/ and to stay inside the one CI glob.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
export TMPDIR

python3 - "$ROOT/hooks" <<'PY'
import os
import sys

sys.path.insert(0, sys.argv[1])
import foreman_state as fs

tmp = os.environ["TMPDIR"]
passed = failed = 0


def check(name, got, want):
    global passed, failed
    if got == want:
        print(f"  ok    {name}")
        passed += 1
    else:
        print(f"  FAIL  {name}: got {got!r}, want {want!r}")
        failed += 1


print("the directory")

check("state_dir is one directory under TMPDIR",
      os.path.dirname(fs.state_dir("abc")), tmp)
check("state_dir is named for the session",
      os.path.basename(fs.state_dir("abc")), "foreman-abc")
check("state_dir creates it", os.path.isdir(fs.state_dir("abc")), True)

# create=False is what the readers use, so a Stop with nothing recorded must not
# leave a directory behind for SessionEnd to find.
check("create=False does not create it",
      os.path.exists(fs.state_dir("never-seen", create=False)), False)

# A session id is not a filename. Claude Code's are UUIDs, but nothing in the
# payload promises that, and one separator would put the markers somewhere else
# entirely, where the other hook would never look.
check("a separator in the session id is stripped",
      os.path.basename(fs.state_dir("a/../b")), "foreman-a..b")
check("and it stays directly under TMPDIR",
      os.path.dirname(fs.state_dir("a/../b")), tmp)

# Every function takes the empty session id, because session_id is read from the
# payload with a "" default and no hook checks it before calling.
check("no session id yields no path", fs.state_dir(""), "")
check("no session id marks nothing", fs.mark("", "x"), False)
check("no session id is never marked", fs.marked("", "x"), False)
check("no session id lists nothing", fs.marks("", "wrote-"), [])

print()
print("the dedupe contract")

# already_flagged in after_edit.py returns this value directly. Inverting it
# would either nudge on every edit forever or never nudge at all.
check("first mark reports it was new", fs.mark("dd", "seen"), False)
check("second mark reports it existed", fs.mark("dd", "seen"), True)
check("marked sees it", fs.marked("dd", "seen"), True)
check("marked is False for another name", fs.marked("dd", "other"), False)

print()
print("bodies and the prefix filter")

fs.mark("bodies", "wrote-1", "app/refunds.py")
fs.mark("bodies", "wrote-2", "app/ledger.py")
fs.mark("bodies", "tests-ran")
check("marks returns the bodies, sorted by marker name",
      fs.marks("bodies", "wrote-"), ["app/refunds.py", "app/ledger.py"])
# The Stop check reads "wrote-" and must not pick up its own bookkeeping markers.
check("marks ignores a marker outside the prefix",
      fs.marks("bodies", "tests-"), [""])
check("marks is empty for an unused prefix", fs.marks("bodies", "nope-"), [])
check("marks is empty for an unknown session", fs.marks("no-such", "wrote-"), [])

# A recorded path is arbitrary text, and sorted() is what makes the nudge stable.
fs.mark("overwrite", "wrote-1", "first")
fs.mark("overwrite", "wrote-1", "second")
check("re-marking replaces the body", fs.marks("overwrite", "wrote-"), ["second"])

print()
print("clear")

fs.mark("bye", "tests-ran")
here = fs.state_dir("bye", create=False)
check("the directory exists before clearing", os.path.isdir(here), True)
fs.clear("bye")
check("clear removes it", os.path.exists(here), False)
# SessionEnd fires for every session, including ones that recorded nothing.
check("clear on a session that never existed is silent", fs.clear("ghost"), None)
check("clear with no session id is silent", fs.clear(""), None)

print()
print("fails open")

# Every caller treats a falsey answer as "stay quiet" or "nudge anyway", and none
# of them catch. A raise here would take the whole hook down with it, which for
# the credential gate means blocking an edit it never even read.
blocked = os.path.join(tmp, "foreman-blocked")
open(blocked, "w").close()  # a file where the directory should be
check("state_dir returns '' when the path is a file", fs.state_dir("blocked"), "")
check("mark returns False when the path is a file", fs.mark("blocked", "x"), False)
check("marked returns False when the path is a file", fs.marked("blocked", "x"), False)
check("marks returns [] when the path is a file", fs.marks("blocked", "x"), [])

# A marker name is not a path either. "wrote-a/b" would otherwise try to write
# into a subdirectory that does not exist.
check("a separator in a marker name is replaced", fs.mark("names", "wrote-a/b"), False)
check("and the marker is readable back",
      fs.marks("names", "wrote-a"), [""])

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
