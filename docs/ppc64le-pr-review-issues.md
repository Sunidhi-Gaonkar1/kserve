# PR #5578 — Community Review Issues & Solutions

**PR Title:** feat: added ppc64le support to ARTExplainer  
**PR Link:** https://github.com/kserve/kserve/pull/5578  
**Reviewers:** spolti (maintainer), cjohannsen-cloudera  
**Files Changed:** `python/artexplainer.Dockerfile`, `.github/workflows/artexplainer-ppc64le-docker-publish.yml`

---

## Table of Contents

1. [Issue 1 — TOML structure broken by sed insertion (CRITICAL)](#issue-1)
2. [Issue 2 — Runtime shared libraries missing in production stage (CRITICAL)](#issue-2)
3. [Issue 3 — Non-reproducible ppc64le builds (HIGH)](#issue-3)
4. [Issue 4 — Maintainer objection: keep changes out of main kserve pyproject.toml (HIGH)](#issue-4)
5. [Issue 5 — Duplicate packages and missing --no-install-recommends in apt-get (MEDIUM)](#issue-5)
6. [Issue 6 — python/kserve/** missing from ppc64le workflow path filter (MEDIUM)](#issue-6)
7. [Issue 7 — QEMU not scoped to linux/ppc64le (LOW)](#issue-7)
8. [Issue 8 — Wrong branch name in workflow trigger (LOW)](#issue-8)
9. [Issue 9 — Hardcoded version pins not tracked in kserve-deps.env (LOW)](#issue-9)

---

<a name="issue-1"></a>
## Issue 1 — TOML Structure Broken by `sed` Insertion

**Severity:** 🔴 CRITICAL  
**Reviewer:** cjohannsen-cloudera  
**File:** `python/artexplainer.Dockerfile` (line 31–54)

---

### What is the Problem?

TOML files have a strict sectioning rule: once you open a new table header like
`[[tool.uv.index]]`, every key-value pair that follows belongs to **that new
section** — not the one before it.

In the current Dockerfile the `sed` command inserts `[[tool.uv.index]]`
immediately after the `index-strategy = ...` line, which sits **inside** the
`[tool.uv]` section. This splits the `[tool.uv]` section in half.

---

### Exact Code That Causes the Problem

In `python/artexplainer.Dockerfile`, the RUN block for the kserve patch:

```dockerfile
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
            -e '/^index-strategy\s*=.*/a [[tool.uv.index]]' \   # <-- inserted HERE
            -e '/^index-strategy\s*=.*/a name = "ppc64le-wheels"' \
            -e '/^index-strategy\s*=.*/a url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
            -e '/^index-strategy\s*=.*/a explicit = true' \
            ...
            kserve/pyproject.toml && \
        cd kserve && uv lock && \
    fi
```

The actual content of `python/kserve/pyproject.toml` around that area is:

```toml
[tool.uv]
index-strategy = "unsafe-best-match"
override-dependencies = [          # <-- THIS must stay inside [tool.uv]
    "urllib3>=2.7.0",    # CVE-2026-21441
    "aiohttp>=3.13.4",   # CVE-2026-34520
    "h11>=0.16.0",       # CVE-2025-43859
    "cryptography>=50.0.0",
    "python-multipart>=0.0.27",
    "pyjwt>=2.13.0",
    "pyasn1>=0.6.4",
    "pillow>=12.3.0",
]
```

---

### What Actually Happens (Step by Step)

**Before `sed` runs — valid TOML:**

```toml
[tool.uv]
index-strategy = "unsafe-best-match"
override-dependencies = [
    "urllib3>=2.7.0",
    "aiohttp>=3.13.4",
    ...
    "pillow>=12.3.0",
]
```

**After `sed` inserts `[[tool.uv.index]]` right after `index-strategy` line — broken TOML:**

```toml
[tool.uv]
index-strategy = "unsafe-best-match"

[[tool.uv.index]]                    # <-- NEW SECTION OPENS HERE
name = "ppc64le-wheels"
url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"
explicit = true

override-dependencies = [            # <-- NOW PARSED AS tool.uv.index[0].override-dependencies
    "urllib3>=2.7.0",                #     NOT tool.uv.override-dependencies
    ...
]
```

`uv` silently ignores `override-dependencies` on the index struct because it
does not recognise it there. So `uv lock` succeeds with **no error**, but the
CVE version pins are completely ignored. The ppc64le image resolves packages at
whatever version `adversarial-robustness-toolbox` pulls in — potentially
shipping old, vulnerable versions like `urllib3 < 2.7.0` (CVE-2026-21441).

---

### Solution

Append the `[[tool.uv.index]]` block **after** the closing `]` of
`override-dependencies`, not in the middle of the `[tool.uv]` section.
The safest anchor is the `[build-system]` header which is guaranteed to come
after the entire `[tool.uv]` block:

```dockerfile
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
            -e '/^\[build-system\]/i\\' \
            -e '/^\[build-system\]/i [[tool.uv.index]]' \
            -e '/^\[build-system\]/i name = "ppc64le-wheels"' \
            -e '/^\[build-system\]/i url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
            -e '/^\[build-system\]/i explicit = true' \
            kserve/pyproject.toml; \
    fi
```

**Result — valid TOML, CVE pins preserved:**

```toml
[tool.uv]
index-strategy = "unsafe-best-match"
override-dependencies = [
    "urllib3>=2.7.0",   # CVE pins still active
    ...
    "pillow>=12.3.0",
]

[[tool.uv.index]]                    # <-- appended AFTER [tool.uv] closes
name = "ppc64le-wheels"
url  = "https://wheels.developerfirst.ibm.com/ppc64le/linux"
explicit = true

[build-system]
...
```

---

<a name="issue-2"></a>
## Issue 2 — Runtime Shared Libraries Missing in Production Stage

**Severity:** 🔴 CRITICAL  
**Reviewer:** cjohannsen-cloudera  
**File:** `python/artexplainer.Dockerfile` (production stage, line 131 onwards)

---

### What is the Problem?

The Docker build uses a **multi-stage build**. The builder stage compiles
native Python extensions (numpy, scipy, pillow, h5py) from source on ppc64le
because no PyPI wheels exist. To do this it installs **dev packages**:

```dockerfile
apt-get install -y ... libopenblas-dev gfortran cmake libhdf5-dev libjpeg-dev
```

The `-dev` suffix means these packages contain header files and static
libraries used at **compile time**. They do not contain the shared libraries
(`.so` files) needed at **runtime**.

When the production stage copies the virtual environment from the builder
stage, the compiled `.so` extension files come along — but the shared
libraries they link against (`libopenblas.so.0`, `libgfortran.so.5`, etc.)
do not, because they were only in the builder stage.

---

### What Actually Happens (Step by Step)

**Build stage — works fine:**

```
builder layer:
  apt-get install libopenblas-dev   →  installs libopenblas-dev + libopenblas.so.0
  uv sync                           →  compiles numpy, links against libopenblas.so.0
  numpy/_core/_multiarray_umath.so  →  built, references libopenblas.so.0
```

**Production stage — runtime crash:**

```
prod layer:
  COPY --from=builder $VIRTUAL_ENV  →  copies numpy/_core/_multiarray_umath.so
  # libopenblas.so.0 is NOT here — was never installed in prod stage

  $ python -c "import numpy"
  ImportError: libopenblas.so.0: cannot open shared object file: No such file or directory
```

This means even though the container starts (the `artserver` process itself
loads), **any inference request that touches numpy/scipy/h5py will crash**.

---

### Solution

Add an explicit runtime library installation to the production stage, guarded
behind the same `ppc64le` architecture check used everywhere else:

```dockerfile
# ------------------ Production stage ------------------
FROM ${BASE_IMAGE} AS prod

# Install ppc64le runtime shared libraries that native extensions link against
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            libopenblas0 \
            libgfortran5 \
            libhdf5-103 \
            libjpeg62-turbo && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*; \
    fi
```

**Package mapping (builder dev → production runtime):**

| Builder (compile-time) | Production (runtime) | Used by |
|---|---|---|
| `libopenblas-dev` | `libopenblas0` | numpy, scipy |
| `gfortran` | `libgfortran5` | scipy (Fortran routines) |
| `libhdf5-dev` | `libhdf5-103` | h5py |
| `libjpeg-dev` | `libjpeg62-turbo` | pillow |

---

<a name="issue-3"></a>
## Issue 3 — Non-Reproducible ppc64le Builds

**Severity:** 🔴 HIGH  
**Reviewer:** cjohannsen-cloudera  
**File:** `python/artexplainer.Dockerfile` (lines 51, 103)

---

### What is the Problem?

Every other architecture (amd64, arm64) uses a **committed `uv.lock` file**.
When `uv sync --frozen` (or `uv sync --no-cache`) is run against a committed
lockfile, the exact same dependency versions are installed on every build —
this is **reproducible**.

For ppc64le, the current approach runs `uv lock` **live during the Docker
build**:

```dockerfile
cd kserve && uv lock && ...
cd artexplainer && uv lock && ...
```

This queries PyPI and `wheels.developerfirst.ibm.com` at build time and
resolves the latest satisfying versions. Two builds a week apart can install
different versions of the same package.

---

### What Actually Happens (Example)

```
Build on Monday:
  uv lock  →  resolves adversarial-robustness-toolbox 1.18.1
              scikit-learn 1.6.1

Build on Friday (after ART releases 1.18.2):
  uv lock  →  resolves adversarial-robustness-toolbox 1.18.2
              scikit-learn 1.7.0   ← different version, untested

  Result: Friday image behaves differently from Monday image
          even though the source commit is identical.
```

Additionally, if `wheels.developerfirst.ibm.com` is temporarily unreachable:

```
uv lock  →  hangs waiting for index
             build times out or fails with a network error
             no fallback, no cached result
```

---

### Solution

**Option A (preferred by project pattern):** Commit a `uv.lock.ppc64le` file
generated on a ppc64le machine, copy it into place in the Dockerfile, and use
`uv sync --frozen` so the lock is never regenerated at build time.

```dockerfile
# Copy ppc64le-specific lockfile into place before syncing
COPY kserve/uv.lock.ppc64le /tmp/kserve_ppc64le_uv.lock

RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock; \
    fi

RUN cd kserve && uv sync --frozen --no-cache
```

**Option B:** Document clearly (in the PR description and in a comment in the
Dockerfile) that ppc64le builds are intentionally non-frozen and explain the
trade-off. The maintainer must explicitly accept this before merge.

---

<a name="issue-4"></a>
## Issue 4 — Maintainer Objection: Keep Changes Out of Main `kserve` pyproject.toml

**Severity:** 🟠 HIGH  
**Reviewer:** spolti (maintainer)  
**File:** `python/kserve/pyproject.toml`

---

### What is the Problem?

The original version of the PR directly modified `python/kserve/pyproject.toml`
to add the IBM ppc64le wheel index. spolti's explicit feedback was:

> *"Why not keep these into the art explainer pyproject.toml only? …  
> I would like to not have dozens of lines added to the main module to build
> just one container. Ideally, it would be best to live only under the ppc64
> builds."*

Modifying the main `kserve` package's config to support one specific
architecture build of one container is the wrong scope. It forces every
developer who runs `uv sync` on the main kserve package on any architecture
to deal with an extra index they don't need.

---

### Current Approach (Already Partially Correct)

The current Dockerfile in this PR uses `sed` to **patch the file only inside
the Docker build context** — the committed file on disk is not changed:

```dockerfile
COPY kserve/pyproject.toml kserve/uv.lock kserve/   # copy into build context
RUN if [ "$(uname -m)" = "ppc64le" ]; then
        sed -i ... kserve/pyproject.toml              # modify only inside builder
        cd kserve && uv lock
        cp uv.lock /tmp/kserve_ppc64le_uv.lock        # save patched lock
    fi
```

This is the right direction. The source file `python/kserve/pyproject.toml`
in the repository is never changed.

---

### What Still Needs to Be Done

1. Confirm in the PR description that `python/kserve/pyproject.toml` is **not
   modified** in the commit diff — the community review was based on an earlier
   version of the PR that did modify it directly.
2. Verify the `git diff` for the PR shows only `artexplainer.Dockerfile` and
   the new workflow file as changed files, not `python/kserve/pyproject.toml`.

---

<a name="issue-5"></a>
## Issue 5 — Duplicate Packages and Missing `--no-install-recommends`

**Severity:** 🟠 MEDIUM  
**Reviewer:** cjohannsen-cloudera  
**File:** `python/artexplainer.Dockerfile` (line 9)

---

### What is the Problem?

The `apt-get install` line for ppc64le has two issues:

1. `pkg-config` appears **twice**
2. `libssl-dev` appears **twice**
3. The ppc64le block is **missing `--no-install-recommends`**

---

### Exact Problematic Code

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends curl python3-dev build-essential && \
    if [ "$(uname -m)" = "ppc64le" ]; then apt-get install pkg-config libssl-dev gcc gfortran cmake pkg-config libssl-dev libopenblas-dev libjpeg-dev libhdf5-dev wget -y; fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

The first `apt-get install` call correctly uses `--no-install-recommends`.
The second (ppc64le) call omits it, and lists `pkg-config` and `libssl-dev`
twice each. On a slow QEMU-emulated ppc64le build this means pulling in many
extra unnecessary packages, increasing build time and image size.

---

### Solution

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl python3-dev build-essential && \
    if [ "$(uname -m)" = "ppc64le" ]; then \
        apt-get install -y --no-install-recommends \
            pkg-config libssl-dev gcc gfortran cmake \
            libopenblas-dev libjpeg-dev libhdf5-dev wget; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

**Changes made:**
- Added `--no-install-recommends` to the ppc64le block
- Removed duplicate `pkg-config`
- Removed duplicate `libssl-dev`
- Moved the `-y` flag before the package list (standard ordering)

---

<a name="issue-6"></a>
## Issue 6 — `python/kserve/**` Missing from ppc64le Workflow Path Filter

**Severity:** 🟠 MEDIUM  
**Reviewer:** cjohannsen-cloudera  
**File:** `.github/workflows/artexplainer-ppc64le-docker-publish.yml` (line 16)

---

### What is the Problem?

GitHub Actions `pull_request.paths` filters control which PRs trigger a
workflow. The ppc64le workflow currently filters on:

```yaml
pull_request:
  paths:
    - "python/artexplainer/**"
    - "python/storage/**"
    - "python/artexplainer.Dockerfile"
    - "!.github/**"
    - "!docs/**"
    - "!**.md"
    - ".github/workflows/artexplainer-ppc64le-docker-publish.yml"
    - ".github/actions/free-up-disk-space/**"
```

Notice that `python/kserve/**` is absent. Compare this to the existing
`artexplainer-docker-publish.yml` which does include it:

```yaml
pull_request:
  paths:
    - "python/artexplainer/**"
    - "python/kserve/**"           # <-- present in amd64/arm64 workflow
    - "python/storage/**"
    - ...
```

The Dockerfile installs the `kserve` Python package as a dependency
(`kserve @ file:///${PROJECT_ROOT}/../kserve`). So a PR that only changes
files inside `python/kserve/` will:

- ✅ Trigger the `artexplainer-docker-publish.yml` (amd64/arm64) workflow
- ❌ NOT trigger the `artexplainer-ppc64le-docker-publish.yml` workflow

A breaking kserve change can silently ship in a broken ppc64le image on the
next version tag.

---

### Solution

Add `"python/kserve/**"` to the paths filter, matching the existing workflow:

```yaml
pull_request:
  paths:
    - "python/artexplainer/**"
    - "python/kserve/**"           # <-- add this line
    - "python/storage/**"
    - "python/artexplainer.Dockerfile"
    - "!.github/**"
    - "!docs/**"
    - "!**.md"
    - ".github/workflows/artexplainer-ppc64le-docker-publish.yml"
    - ".github/actions/free-up-disk-space/**"
```

---

<a name="issue-7"></a>
## Issue 7 — QEMU Not Scoped to `linux/ppc64le`

**Severity:** 🟡 LOW  
**Reviewer:** cjohannsen-cloudera  
**File:** `.github/workflows/artexplainer-ppc64le-docker-publish.yml` (lines 57–60, 93–96)

---

### What is the Problem?

The `docker/setup-qemu-action` step registers CPU emulation (binfmt) handlers
in the kernel so that Docker can run foreign architecture binaries. When called
without a `platforms` argument it registers handlers for **all** supported
emulated architectures (arm, arm64, s390x, ppc64le, riscv64, etc.).

Current code in both `test` and `push` jobs:

```yaml
- name: Setup QEMU
  uses: docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130
  with:
    cache-image: true    # no 'platforms' key
```

This registers binfmt for every architecture unnecessarily, adding ~30–60
seconds per run with no benefit since only `linux/ppc64le` is needed.

The existing `agent-docker-publish.yml` in the same repository already scopes
this correctly and is the pattern to follow.

---

### Solution

Add `platforms: linux/ppc64le` to both QEMU setup steps:

```yaml
# In the 'test' job:
- name: Setup QEMU
  uses: docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130
  with:
    platforms: linux/ppc64le     # <-- add this
    cache-image: true

# In the 'push' job:
- name: Setup QEMU
  uses: docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130
  with:
    platforms: linux/ppc64le     # <-- add this
    cache-image: true
```

---

<a name="issue-8"></a>
## Issue 8 — Wrong Branch Name in Workflow Trigger

**Severity:** 🟡 LOW  
**File:** `.github/workflows/artexplainer-ppc64le-docker-publish.yml` (line 7)

---

### What is the Problem?

The `push.branches` trigger in the ppc64le workflow still contains the
contributor's personal development branch name instead of `master`:

```yaml
on:
  push:
    branches:
      - art-prerna       # <-- should be 'master'
```

This means the workflow will never trigger when a PR is merged to `master`.
The `latest` Docker image for ppc64le will never be published automatically
after merge. All other workflows in the repository use `master` here.

---

### Solution

```yaml
on:
  push:
    branches:
      - master           # <-- correct branch
    tags:
      - v*
```

---

<a name="issue-9"></a>
## Issue 9 — Hardcoded Version Pins Not Tracked in `kserve-deps.env`

**Severity:** 🟡 LOW  
**Reviewer:** cjohannsen-cloudera  
**File:** `python/artexplainer.Dockerfile` (lines 77–79)

---

### What is the Problem?

The kserve project uses `kserve-deps.env` as its **canonical version
registry** for dependency versions. Tools, infrastructure components, and Go
dependencies are all tracked there (e.g. `UV_VERSION=0.7.8`,
`KSERVE_VERSION=v0.20.0`).

The ppc64le Dockerfile hardcodes three version pins directly in the `sed`
command:

```dockerfile
sed -i \
    -e '/^    "h5py/a\    "scikit-learn==1.6.1",' \
    -e '/^    "h5py/a\    "scipy==1.15.2",' \
    -e '/^    "h5py/a\    "ml-dtypes==0.5.1",' \
    artexplainer/pyproject.toml
```

These versions are isolated. If `adversarial-robustness-toolbox` (ART) raises
its minimum `scikit-learn` requirement to `1.7.0`:

- The amd64/arm64 CI uses committed `uv.lock` — still passes (lock file
  pre-computed, no conflict visible)
- The ppc64le Dockerfile injects `scikit-learn==1.6.1` which now conflicts —
  `uv lock` fails **only on ppc64le** during Docker build

This is a silent, hard-to-trace breakage because the x86/arm64 CI will keep
passing while ppc64le builds fail.

---

### Solution

Add the version pins to `kserve-deps.env`:

```bash
# ppc64le-specific Python package pins (no PyPI wheels available)
PPC64LE_SCIKIT_LEARN_VERSION=1.6.1
PPC64LE_SCIPY_VERSION=1.15.2
PPC64LE_ML_DTYPES_VERSION=0.5.1
```

Then reference them in the Dockerfile using build args:

```dockerfile
ARG PPC64LE_SCIKIT_LEARN_VERSION=1.6.1
ARG PPC64LE_SCIPY_VERSION=1.15.2
ARG PPC64LE_ML_DTYPES_VERSION=0.5.1

RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
            -e "/^    \"h5py/a\\    \"scikit-learn==${PPC64LE_SCIKIT_LEARN_VERSION}\"," \
            -e "/^    \"h5py/a\\    \"scipy==${PPC64LE_SCIPY_VERSION}\"," \
            -e "/^    \"h5py/a\\    \"ml-dtypes==${PPC64LE_ML_DTYPES_VERSION}\"," \
            artexplainer/pyproject.toml; \
    fi
```

---

## Overall Summary Table

| # | Issue | Severity | File | Fix Needed |
|---|-------|----------|------|------------|
| 1 | TOML structure broken — CVE pins silently dropped | 🔴 CRITICAL | `artexplainer.Dockerfile:33` | Move `[[tool.uv.index]]` insertion to after `[build-system]` anchor |
| 2 | Runtime `.so` libs missing in production stage | 🔴 CRITICAL | `artexplainer.Dockerfile:131` | Install `libopenblas0`, `libgfortran5`, `libhdf5-103`, `libjpeg62-turbo` in prod stage |
| 3 | Live `uv lock` at build time — non-reproducible | 🔴 HIGH | `artexplainer.Dockerfile:51,103` | Commit ppc64le lockfiles and use `--frozen` |
| 4 | Main kserve pyproject.toml must not be modified | 🟠 HIGH | `python/kserve/pyproject.toml` | Confirm no committed change; sed-in-Dockerfile approach is correct |
| 5 | ~~Duplicate apt packages, missing `--no-install-recommends`~~ | ✅ FIXED | `artexplainer.Dockerfile:9` | Deduplicated packages, added `--no-install-recommends` |
| 6 | `python/kserve/**` missing from ppc64le CI path filter | 🟠 MEDIUM | `artexplainer-ppc64le-docker-publish.yml:16` | Add `python/kserve/**` to paths |
| 7 | QEMU not scoped to `linux/ppc64le` | 🟡 LOW | `artexplainer-ppc64le-docker-publish.yml:57,93` | Add `platforms: linux/ppc64le` |
| 8 | Wrong branch name (`art-prerna` vs `master`) | 🟡 LOW | `artexplainer-ppc64le-docker-publish.yml:7` | Change to `master` |
| 9 | Version pins not tracked in `kserve-deps.env` | 🟡 LOW | `artexplainer.Dockerfile:77` | Move pins to `kserve-deps.env`, reference via build args |

---

## Recommended Fix Order

```
1. Fix Issue 8 (wrong branch) — trivial, 1 line
2. Fix Issue 5 (apt dedup + --no-install-recommends) — trivial, 1 block
3. Fix Issue 7 (QEMU scope) — trivial, 2 lines
4. Fix Issue 6 (path filter) — trivial, 1 line
5. Fix Issue 1 (TOML anchor) — CRITICAL, test with uv lock locally
6. Fix Issue 2 (runtime libs) — CRITICAL, test import numpy/scipy/h5py in prod container
7. Fix Issue 3 (reproducibility) — generate and commit ppc64le lockfiles
8. Fix Issue 9 (version tracking) — move pins to kserve-deps.env
9. Confirm Issue 4 (no committed pyproject.toml change) — verify git diff
```
