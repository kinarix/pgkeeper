# SPDX-License-Identifier: Apache-2.0
#
# pgkeeper-dashboard image. Built by `make docker-build-dashboard` from a context staged
# in ./bin holding the static linux binary and module licenses.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
COPY LICENSES/ /LICENSES/
COPY pgkeeper-dashboard /pgkeeper-dashboard
USER 65532:65532
ENTRYPOINT ["/pgkeeper-dashboard"]
