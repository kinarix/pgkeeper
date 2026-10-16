# Contributing to pgkeeper

Thanks for your interest! pgkeeper is in its design phase. Specs and ADRs are where to start.

## Before you start
- Read [`docs/specs/09-phases.md`](docs/specs/09-phases.md) to find the current phase. Only work in scope for that phase is accepted.
- The specs in [`docs/specs/`](docs/specs/) are the source of truth. If a change deviates from them, update the spec in the same pull request and explain why.
- Changes to failover, the lease, fencing or promotion need updated model tests and a chaos-run report (see [`docs/specs/03-ha.md`](docs/specs/03-ha.md) and [`docs/specs/08-testing-and-makefile.md`](docs/specs/08-testing-and-makefile.md)).
- Larger design changes start as an ADR in [`docs/adr/`](docs/adr/README.md).

## Developer Certificate of Origin (DCO)
pgkeeper uses the [Developer Certificate of Origin 1.1](https://developercertificate.org/) instead of a CLA. By adding a `Signed-off-by` line to a commit, you certify that you wrote the change or otherwise have the right to submit it under the project's license (Apache-2.0).

Every commit in a pull request must be signed off:

```sh
git commit -s -m "Describe the change"
```

This adds a line using your configured `user.name` and `user.email`:

```
Signed-off-by: Your Name <you@example.com>
```

Forgot? Fix the last commit with `git commit --amend -s --no-edit`, or a whole branch with `git rebase --signoff main`, then force-push your branch.

Pull requests with unsigned commits can't be merged: CI runs `make dco`, which checks that every non-merge commit is signed off by its author. Run it locally before pushing (`make dco` once Phase 0 lands).

### The DCO text
```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

## License headers
New source files start with an SPDX identifier, for example in Go:

```go
// SPDX-License-Identifier: Apache-2.0
```

## License
By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
