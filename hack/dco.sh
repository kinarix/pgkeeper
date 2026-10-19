#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# DCO check (08 §5.3): every non-merge commit in <base>..HEAD needs a
# Signed-off-by trailer whose email equals the commit's author email
# (case-insensitive). Co-author trailers don't count. Pure git.
#
# Usage: dco.sh <base>
set -euo pipefail

base=$1
failed=0
for c in $(git rev-list --no-merges "$base..HEAD"); do
	author=$(git log -1 --format='%ae' "$c" | tr '[:upper:]' '[:lower:]')
	signers=$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$c" |
		sed -n 's/.*<\([^>]*\)>.*/\1/p' | tr '[:upper:]' '[:lower:]')
	if ! grep -qxF "$author" <<<"$signers"; then
		if [[ -z "$signers" ]]; then why="no Signed-off-by"; else why="no Signed-off-by from author <$author>"; fi
		printf '  %s %s (%s)\n' "$(git log -1 --format='%h' "$c")" "$(git log -1 --format='%s' "$c")" "$why"
		failed=1
	fi
done
if ((failed)); then
	echo "DCO check failed for the commits above. Fix with:"
	echo "  git rebase --signoff $base && git push --force-with-lease"
	exit 1
fi
echo "DCO check passed ($base..HEAD)"
