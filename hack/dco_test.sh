#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests for hack/dco.sh against throwaway repositories (Phase 0 acceptance).
set -euo pipefail

dco=$(cd "$(dirname "$0")" && pwd)/dco.sh
fail=0

# new_repo creates a repo with one base commit and prints its path.
new_repo() {
	local d
	d=$(mktemp -d)
	git -C "$d" init -q -b main
	git -C "$d" config user.name Alice
	git -C "$d" config user.email alice@example.com
	git -C "$d" commit -q --allow-empty -m base
	echo "$d"
}
commit() { git -C "$1" commit -q --allow-empty "${@:2}"; }

expect() { # expect <pass|fail> <name> <repo> [output must contain]
	local out rc=0
	out=$(cd "$3" && "$dco" main 2>&1) || rc=$?
	if [[ $1 == pass && $rc != 0 ]] || [[ $1 == fail && $rc == 0 ]] ||
		[[ -n "${4:-}" && "$out" != *"$4"* ]]; then
		printf 'FAIL %s (rc=%s)\n%s\n' "$2" "$rc" "$out"
		fail=1
	else
		printf 'ok   %s\n' "$2"
	fi
	rm -rf "$3"
}

r=$(new_repo); git -C "$r" switch -q -c topic
commit "$r" -s -m one; commit "$r" -s -m two
expect pass "signed-off branch" "$r"

r=$(new_repo); git -C "$r" switch -q -c topic
commit "$r" -s -m signed; commit "$r" -m unsigned
expect fail "unsigned commit" "$r" "unsigned (no Signed-off-by)"

r=$(new_repo); git -C "$r" switch -q -c topic
commit "$r" -m "signed by bob" -m "Signed-off-by: Bob <bob@example.com>"
expect fail "signed off by someone other than the author" "$r" "no Signed-off-by from author <alice@example.com>"

r=$(new_repo); git -C "$r" switch -q -c topic
commit "$r" -m "case differs" -m "Signed-off-by: Alice <ALICE@Example.com>"
expect pass "email compared case-insensitively" "$r"

r=$(new_repo); git -C "$r" switch -q -c topic
commit "$r" -m "co-author only" -m "Co-authored-by: Alice <alice@example.com>"
expect fail "co-author trailer does not count" "$r"

r=$(new_repo); git -C "$r" switch -q -c side
commit "$r" -s -m side; git -C "$r" switch -q main
git -C "$r" switch -q -c topic; commit "$r" -s -m topic
git -C "$r" merge -q --no-ff --no-edit side
expect pass "only unsigned commit is a merge commit" "$r"

r=$(new_repo); git -C "$r" switch -q -c topic; commit "$r" -m unsigned
expect fail "prints the fix" "$r" "git rebase --signoff main"

exit "$fail"
