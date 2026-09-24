<!-- SPDX-FileCopyrightText: Iridesium -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Contributing

## Licensing and provenance

Contributions are accepted under the **Developer Certificate of Origin** (DCO)
version 1.1, reproduced below. **Authors retain copyright in their
contributions.** There is no copyright assignment and no contributor licence
agreement.

**What you license by submitting a contribution:**

> By submitting a contribution to this repository, you license it under the
> GNU General Public License, version 3 only (`GPL-3.0-only`), together with
> the Additional Permission in [`LICENSE.EXCEPTION`](LICENSE.EXCEPTION),
> version 1.0 of 24 September 2026. Contributions within `stubs/` are licensed
> under the MIT licence in [`stubs/LICENSE`](stubs/LICENSE) instead. You retain
> copyright.

The second half of that sentence is the point of it. Tiamat Weather promises mod
authors that a work interacting with it only through its exports, the engine's
scripting API or the network protocol is independent and carries no copyleft
obligation. That promise is worth exactly what every copyright holder in the
tree has granted, so a contribution licensed under the bare GPL would leave a
hole in it. Licensing under the GPL *with* the Additional Permission closes that
hole for the code you add, and your DCO sign-off is the record of having done
so.

One consequence worth stating plainly: because copyright stays with each author,
the project cannot be relicensed, and the text of the Additional Permission
cannot be changed for code you wrote, without your agreement. Iridesium
maintains the text and can amend it for its own code; a new version gets a new
number and date, and code contributed under an earlier version stays under that
version unless its author agrees otherwise. This is a deliberate trade —
contributor-friendly, and it makes licensing changes hard on purpose. If the
project ever needs a CLA, that decision has to be made before outside
contributions accumulate, not after.

The same terms, with the same permission adapted to each work, apply to the
Tiamat engine and to each of Iridesium's default-mod repositories; the checklist
that keeps them identical is the engine's
`docs/licensing/mod-repo-checklist.md`.

### Sign-off is required

Every commit must carry a `Signed-off-by` trailer matching its author:

```
Signed-off-by: Your Name <your.email@example.com>
```

`git commit -s` adds it. To get it automatically, point git at the repo's hooks
once after cloning:

```
git config core.hooksPath .githooks
```

`scripts/check-dco.sh` rejects any commit without a valid, author-matching
sign-off, and `scripts/check-spdx.sh` any source file without both SPDX lines.
Run both before you push.

## Developer Certificate of Origin 1.1

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
