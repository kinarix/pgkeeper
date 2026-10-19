# SPDX-License-Identifier: Apache-2.0
#
# Tools image (02 §2): static pgkeeper-instance and wal-g, no shell. Mounted
# into Postgres pods as an image volume, or copied by an init container
# running `/pgkeeper-instance install --to /pgkeeper/bin`.
# Built by `make docker-build-tools` from a context staged in ./bin.
FROM scratch
COPY LICENSES/ /LICENSES/
COPY wal-g /wal-g
COPY pgkeeper-instance /pgkeeper-instance
ENTRYPOINT ["/pgkeeper-instance"]
