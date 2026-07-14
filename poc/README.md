# Job Trigger-Time Vars — Demo Script

This POC lets a job declare vars in the pipeline YAML that are resolved at
trigger time — per-build overrides layered over declared defaults — and adds
an inbound webhook endpoint that triggers a job with vars extracted from the
webhook payload (e.g. a GitHub `pull_request` event).

Steps reference the vars as build-local vars: `((.:branch))`.

> **Non-production PoC:** trigger vars are deliberately non-secret. Explicit
> overrides are stored with build metadata and may be returned to anyone who
> can view that metadata. Do not pass passwords, tokens, or other credentials.
> Secret parameters would require a separate design integrating redaction,
> authorization, and Concourse credential managers.

```yaml
jobs:
- name: build-pull-request
  vars:
    pr_number: {type: number, required: true}
    head_sha: {required: true}
    head_ref: {required: true}
    base_ref: {required: true}
  trigger_webhooks:
  - name: github-pr
    authentication:
      hmac_sha256:
        secret: ((github-webhook-secret))
        header: X-Hub-Signature-256
        prefix: sha256=
    delivery_id: {header: X-GitHub-Delivery}
    filter:
      action: {one_of: [opened, reopened, synchronize, ready_for_review]}
      pull_request.draft: false
    var_mapping:
      pr_number: number
      head_sha: pull_request.head.sha
      head_ref: pull_request.head.ref
      base_ref: pull_request.base.ref
```

Declarations support `string` (the default type), `number`, `boolean`, and
`enum`. Manual, API, UI, and webhook triggers reject undeclared values, nulls,
type mismatches, missing required values, and enum values outside `options`.
Automatic builds do not manufacture required values: if a required var has no
value and the plan references it, normal runtime interpolation reports the
unresolved var.

Only explicit overrides are persisted. Defaults are read from the current job
configuration when execution starts, including for reruns.

## Run the published PoC image

The fork-only publishing workflow builds a Linux/AMD64 debug image from the
`with-fly` Dockerfile target and publishes it to:

```text
ghcr.io/gbrlcrpntr/concourse:job-vars-poc
```

This image is for review and demonstration, not production. From a checkout
of this repository (the Compose file uses the development keys in
`hack/keys`):

```sh
docker pull --platform linux/amd64 ghcr.io/gbrlcrpntr/concourse:job-vars-poc
docker compose -f poc/docker-compose.ghcr.yml up -d
curl --fail http://localhost:8080/api/v1/info
```

Set `CONCOURSE_IMAGE` to an alternate or SHA-pinned registry tag with the same
Compose file. For a locally built tag, prevent the Compose file's normal
registry refresh:

```sh
CONCOURSE_IMAGE=concourse-job-vars-poc:local \
  docker compose -f poc/docker-compose.ghcr.yml up -d --pull never
```

The GHCR package must be made public once after its first publication. The
workflow also publishes `branch-job-vars-poc` and an immutable
`job-vars-poc-<commit-sha>` tag so a demonstration can be pinned to the exact
reviewed source.

## Build & run from source

From the repo root (branch `job-vars-poc`):

```sh
# build web assets, then bring up a dev cluster from this source tree
yarn install && yarn build
docker compose up --build -d

# build the matching fly and log in
go install ./fly
fly -t dev login -c http://localhost:8080 -u test -p test
```

Set the demo pipeline:

```sh
fly -t dev set-pipeline -n -p job-vars-demo -c poc/demo-pipeline.yml
fly -t dev unpause-pipeline -p job-vars-demo
```

The job clones `octocat/Hello-World`, which really has branches `master`,
`test`, and `octocat-patch-1` — so every scene below ends with a visible
`cloned branch: <name> @ <sha>` line in the build log.

## Scene 1 — defaults

Trigger with no overrides; the declared defaults apply.

```sh
fly -t dev trigger-job -j job-vars-demo/build-branch -w
```

Expected in the output:

```
hello from the job-vars demo
target environment: dev
dry run: false
clone depth: 1
cloned branch: master @ 7fd1a60
```

## Scene 2 — fly override

`fly trigger-job` gains `-v NAME=STRING` (and `-y NAME=YAML` for non-string
values), so you can override both text and typed vars:

```sh
fly -t dev trigger-job -j job-vars-demo/build-branch \
  -v branch=test -v greeting=hi -v deploy_env=prod \
  -y clone_depth=2 -y dry_run=true -w
```

Expected:

```
hi from the job-vars demo
target environment: prod
dry run: true
clone depth: 2
cloned branch: test @ b3cbd5b
```

Undeclared vars are rejected:

```sh
fly -t dev trigger-job -j job-vars-demo/build-branch -v nope=x -w
# error: Unexpected Response
# Status: 400 Bad Request
# Body: {"error":"undeclared var(s): nope"}
```

## Scene 3 — UI form

1. Open http://localhost:8080/teams/main/pipelines/job-vars-demo/jobs/build-branch
2. Click the `+` (trigger build) button. Because the job declares vars, a
   form appears instead of immediately triggering, pre-filled with each var's
   default and showing its description ("branch of Hello-World to clone").
   String vars render as text inputs, `clone_depth` as a number field,
   `dry_run` as a checkbox, and `deploy_env` as a dropdown.
3. Edit `branch` to `octocat-patch-1`, `clone_depth` to `2`, toggle
   `dry_run` on, choose `staging` for `deploy_env`, leave `greeting` as
   `hello`, and submit.
4. The new build's log includes:

```
hello from the job-vars demo
target environment: staging
dry run: true
clone depth: 2
cloned branch: octocat-patch-1 @ b1b3f97
```

## Scene 4 — API with a bearer token

`POST .../jobs/:job/builds` now accepts an optional JSON body
`{"vars": {...}}`.

Get a token from the dev cluster's built-in issuer (client `fly:Zmx5`):

```sh
TOKEN=$(curl -s http://localhost:8080/sky/issuer/token \
  -u 'fly:Zmx5' \
  --data-urlencode grant_type=password \
  --data-urlencode username=test \
  --data-urlencode password=test \
  --data-urlencode 'scope=openid profile email federated:id groups' \
  | jq -r .access_token)
```

Trigger with an override:

```sh
curl -i -X POST \
  http://localhost:8080/api/v1/teams/main/pipelines/job-vars-demo/jobs/build-branch/builds \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"vars": {"branch": "test"}}'
# HTTP/1.1 200 OK  + build JSON; the build clones branch "test"
```

Negative case — undeclared vars are a 400:

```sh
curl -i -X POST \
  http://localhost:8080/api/v1/teams/main/pipelines/job-vars-demo/jobs/build-branch/builds \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"vars": {"not_a_var": "x"}}'
# HTTP/1.1 400 Bad Request
# {"error":"undeclared var(s): not_a_var"}
```

## Scene 5 — webhook trigger

The PR demo uses GitHub-compatible HMAC-SHA256 authentication. The configured
secret may be a credential-manager-backed `((var))`; the literal value in this
demo is only for local use. The handler verifies `X-Hub-Signature-256` over the
exact bounded request body before parsing it. Legacy `webhook_token` query
authentication remains available as a mutually exclusive alternative.

`one_of` accepts the GitHub actions that introduce a new buildable PR head,
while the second filter skips draft PRs. `X-GitHub-Delivery` makes retries
idempotent for the same job and webhook. Request bodies are limited to 1 MiB
and raw payloads are not stored.

Compute the signature over the exact file bytes, then post a matching payload:

```sh
WEBHOOK_SECRET=wh-secret
SIGNATURE=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" poc/pr-opened.json | awk '{print $NF}')
curl -i -X POST \
  'http://localhost:8080/api/v1/teams/main/pipelines/job-vars-demo/jobs/build-pull-request/builds/webhook?name=github-pr' \
  -H 'Content-Type: application/json' \
  -H "X-Hub-Signature-256: sha256=$SIGNATURE" \
  -H 'X-GitHub-Delivery: demo-opened-1' \
  --data-binary @poc/pr-opened.json
# HTTP/1.1 201 Created  + build JSON
```

Watch it. The task displays the branch context but fetches and verifies the
immutable `pull_request.head.sha`, avoiding a race if the PR branch moves:

```sh
fly -t dev watch -j job-vars-demo/build-pull-request
# ...
# PR #42: test -> master
# checked out immutable head SHA: b3cbd5bbd7e81436d2eee04537ea2b4c0cad4cdf
```

Sending the same request again with delivery ID `demo-opened-1` returns HTTP
200 and the original build instead of creating a duplicate. A new delivery ID
creates a new build.

A non-matching payload (`action: closed`) is filtered out — no build:

```sh
curl -i -X POST \
  'http://localhost:8080/api/v1/teams/main/pipelines/job-vars-demo/jobs/build-pull-request/builds/webhook?name=github-pr' \
  -H 'Content-Type: application/json' \
  -H "X-Hub-Signature-256: sha256=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" poc/pr-closed.json | awk '{print $NF}')" \
  -H 'X-GitHub-Delivery: demo-closed-1' \
  --data-binary @poc/pr-closed.json
# HTTP/1.1 200 OK
# {"skipped": true}
```

A missing or wrong signature is rejected:

```sh
curl -i -X POST \
  'http://localhost:8080/api/v1/teams/main/pipelines/job-vars-demo/jobs/build-pull-request/builds/webhook?name=github-pr' \
  -H 'Content-Type: application/json' \
  -H 'X-Hub-Signature-256: sha256=deadbeef' \
  -H 'X-GitHub-Delivery: demo-invalid-1' \
  --data-binary @poc/pr-opened.json
# HTTP/1.1 401 Unauthorized
```

## Bonus — reruns copy overrides and use current defaults

Builds store only explicit overrides. Reruns copy those overrides, while all
unoverridden defaults are resolved from the current job configuration when
the rerun executes. For example, the `branch=test` override remains `test`,
even if the configured `branch` default changes:

```sh
# after Scene 2's build (say it was build 2):
fly -t dev rerun-build -j job-vars-demo/build-branch -b 2 -w
# cloned branch: test @ b3cbd5b   <- the explicit override is preserved
```

If an unoverridden default changes between the original build and its rerun,
the rerun sees the new default. Snapshotting resolved defaults instead is an
explicit RFC discussion point; the PoC keeps the simpler override-only model.

## Verification checklist

- [ ] Scene 1: untouched trigger uses defaults (`cloned branch: master`)
- [ ] Scene 2: `fly trigger-job -v branch=test -v greeting=hi -v deploy_env=prod -y clone_depth=2 -y dry_run=true` overrides text and typed vars
- [ ] Scene 3: UI trigger form shows defaults + descriptions and renders text/number/checkbox/dropdown controls
- [ ] Scene 4: API body `{"vars": ...}` overrides; unknown var returns 400
- [ ] Scene 5: signed webhook with a matching `one_of` filter returns 201 and
      checks out the exact head SHA; redelivery returns the original build with
      200; `action: closed` returns 200 `{"skipped": true}` with no build;
      wrong signature returns 401
- [ ] Bonus: `fly rerun-build` copies explicit overrides and resolves current defaults

## Experimenting locally (dev-loop cheat sheet)

The dev cluster runs in docker compose (on this machine the Docker daemon is
provided by `colima`, since Docker Desktop is broken). Services: `db`
(postgres), `web` (ATC + UI on http://localhost:8080, login `test`/`test`),
`worker`.

The PoC `fly` is installed as **`fly-dev`** (symlink to `~/go/bin/fly`), so it
doesn't shadow the stock `fly` used for real deployments. The target is `dev`:

```sh
fly-dev -t dev pipelines
```

### Edit → see it running

| You changed…            | Rebuild with                                          |
| ----------------------- | ----------------------------------------------------- |
| Go (`atc/`, `tsa/`, …)  | `docker compose up --build -d web worker`             |
| Elm/CSS (`web/`)        | `corepack yarn build` — assets propagate live, no restart (use `corepack yarn build-debug` for faster iteration) |
| fly                     | `go build -o ~/go/bin/fly ./fly`                      |

### Logs, tests, lifecycle

```sh
docker compose logs -f web            # ATC logs (worker likewise)

# unit tests: db/gc/scheduler suites need postgres binaries on PATH,
# and must not run in parallel with each other (test-postgres port clash)
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
go test ./atc/api/ ./atc/exec/ ./atc/engine/ ./atc/configvalidate/
go test ./atc/db/                     # slow (~3 min, real postgres)
corepack yarn test                    # 3000+ elm tests

# acceptance suite against the running cluster
go test ./testflight -count=1 -ginkgo.focus "Job trigger-time vars"

docker compose stop / start           # pause / resume the cluster
docker compose down && docker compose up -d    # fresh containers, keeps images
docker compose down -v                # ALSO wipes the database (fresh state)
colima stop / start                   # the underlying docker VM
```
