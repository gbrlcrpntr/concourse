# No-Fork Workaround: External Trigger Relay + Instanced Pipelines

What if we couldn't change Concourse at all? This documents the closest
approximation to job trigger-time vars achievable against **stock Concourse**,
so the POC can be judged against the status quo. The short version: you can
get parameterized triggering, but only by moving the "vars" outside of
Concourse — into set-pipeline-time interpolation driven by an external relay
service.

## Idea

Stock Concourse already has two relevant primitives:

1. **Instanced pipelines** — one pipeline config, many instances keyed by
   `--instance-var` values (`vars.branch="feat-x"` in the API query string).
2. **Set-pipeline-time interpolation** — `((branch))` in the YAML is resolved
   eagerly when the config is PUT, from `-v`/instance vars.

So instead of "trigger job with `branch=feat-x`", the workaround is
"stamp out a pipeline *instance* for `branch=feat-x`, then trigger its job".
Since GitHub can't drive that multi-step API dance itself, a small external
**trigger-relay** service sits between the webhook and Concourse.

## Architecture

```
GitHub PR webhook                     trigger-relay (external service)                Concourse ATC
      |                                        |                                          |
      |--- POST /webhook (X-Hub-Signature-256)>|                                          |
      |                                        |-- verify HMAC over raw body              |
      |                                        |-- switch on action: opened/synchronize   |
      |                                        |                                          |
      |                                        |-- POST /sky/issuer/token (password grant,|
      |                                        |   bot user, client fly:Zmx5) ------------>  bearer token
      |                                        |                                          |
      |                                        |-- GET  /api/v1/teams/main/pipelines/pr-ci/config?vars.branch="feat-x"
      |                                        |     (capture X-Concourse-Config-Version if instance exists)
      |                                        |-- PUT  /api/v1/teams/main/pipelines/pr-ci/config?vars.branch="feat-x"
      |                                        |     Content-Type: application/x-yaml
      |                                        |     X-Concourse-Config-Version: <from GET, omitted when new>
      |                                        |     body: pipeline template YAML (((branch)) baked in)
      |                                        |-- PUT  /api/v1/teams/main/pipelines/pr-ci/unpause?vars.branch="feat-x"
      |                                        |-- POST /api/v1/teams/main/pipelines/pr-ci/jobs/test/builds?vars.branch="feat-x"
      |                                        |                                          |
      |   (action: closed)                     |-- PUT  /api/v1/teams/main/pipelines/pr-ci/archive?vars.branch="feat-x"
```

Notes on the API dance:

- **Token**: the relay logs in as a dedicated bot local user via the password
  grant on `/sky/issuer/token` (same call as poc/README.md Scene 4). Tokens
  expire, so the relay re-fetches on 401.
- **Config version**: `PUT .../config` is compare-and-swap. For an existing
  instance you must echo back the `X-Concourse-Config-Version` header from a
  prior `GET .../config`, otherwise the PUT is rejected; for a brand-new
  instance you omit it.
- **Instance var encoding**: query values are JSON-encoded, i.e. literally
  `?vars.branch="feat-x"` (quotes included, URL-escaped).
- **PR close** maps to `PUT .../archive` so dead instances disappear from the
  dashboard.

## Pipeline template

The relay always PUTs the same template; `((branch))` is interpolated
**eagerly at set-pipeline time** from the instance var — by the time the
pipeline exists, the value is baked into its config:

```yaml
# pr-ci template — instanced by ((branch))
jobs:
- name: test
  plan:
  - task: clone-and-test
    config:
      platform: linux
      image_resource:
        type: registry-image
        source: {repository: alpine/git}
      run:
        path: sh
        args:
        - -exc
        - |
          git clone -b '((branch))' --depth 1 https://github.com/octocat/Hello-World.git repo
          cd repo && echo "cloned branch: $(git rev-parse --abbrev-ref HEAD)"
```

Contrast with the POC: there the same-looking reference is `((.:branch))`, a
*build-local* var resolved lazily at runtime per build, with declared
defaults and API/UI/webhook overrides.

## Relay pseudocode (Go-style, ~80 lines)

```go
var (
    atcURL     = env("ATC_URL")       // http://concourse.example.com
    hmacSecret = env("GITHUB_SECRET") // shared with the GitHub webhook
    botUser    = env("BOT_USERNAME")
    botPass    = env("BOT_PASSWORD")
    template   = mustReadFile("pr-ci.yml")
)

func main() {
    http.HandleFunc("/webhook", handleWebhook) // GitHub -> relay
    http.HandleFunc("/trigger", handleForm)    // humans  -> relay (form)
    http.ListenAndServe(":8000", nil)
}

// --- webhook path -----------------------------------------------------------

func handleWebhook(w http.ResponseWriter, r *http.Request) {
    body := readAll(r.Body)

    // GitHub signs the raw body; reject anything unsigned/mis-signed.
    sig := r.Header.Get("X-Hub-Signature-256") // "sha256=<hex>"
    if !hmac.Equal(sign(hmacSecret, body), decodeHex(sig)) {
        respond(w, 401, "bad signature")
        return
    }

    event := parseJSON(body)
    branch := event.PullRequest.Head.Ref

    switch event.Action {
    case "opened", "synchronize", "reopened":
        if err := deployAndTrigger(branch); err != nil {
            respond(w, 502, err)
            return
        }
        respond(w, 202, "triggered "+branch)
    case "closed":
        atcRequest("PUT", instanceURL("archive", branch), nil)
        respond(w, 202, "archived "+branch)
    default:
        respond(w, 200, "ignored")
    }
}

func deployAndTrigger(branch string) error {
    // 1. compare-and-swap the instance's config
    resp := atcRequest("GET", instanceURL("config", branch), nil)
    version := resp.Header.Get("X-Concourse-Config-Version") // "" if 404 (new)

    put := newRequest("PUT", instanceURL("config", branch), template)
    put.Header.Set("Content-Type", "application/x-yaml")
    if version != "" {
        put.Header.Set("X-Concourse-Config-Version", version)
    }
    if resp := do(put); resp.StatusCode >= 300 {
        return fmt.Errorf("set config: %s", resp.Status) // incl. version conflict
    }

    // 2. unpause (idempotent), 3. trigger
    atcRequest("PUT", instanceURL("unpause", branch), nil)
    resp = atcRequest("POST", instanceURL("jobs/test/builds", branch), nil)
    if resp.StatusCode != 200 && resp.StatusCode != 201 {
        return fmt.Errorf("trigger: %s", resp.Status)
    }
    return nil
}

// --- human path: minimal HTML form (the "UI" lives here, not in Concourse) --

func handleForm(w http.ResponseWriter, r *http.Request) {
    if r.Method == "GET" {
        fmt.Fprint(w, `<form method="POST">
            branch: <input name="branch" value="master"/>
            <button>Trigger</button></form>`)
        return
    }
    if err := deployAndTrigger(r.FormValue("branch")); err != nil {
        respond(w, 502, err)
        return
    }
    respond(w, 200, "triggered "+r.FormValue("branch"))
}

// --- helpers -----------------------------------------------------------------

func instanceURL(suffix, branch string) string {
    return atcURL + "/api/v1/teams/main/pipelines/pr-ci/" + suffix +
        "?vars.branch=" + url.QueryEscape(`"`+branch+`"`) // JSON-encoded value
}

func atcRequest(method, url string, body []byte) *http.Response {
    req := newRequest(method, url, body)
    req.Header.Set("Authorization", "Bearer "+cachedToken()) // /sky/issuer/token
    resp := do(req)                                          // password grant, bot user
    if resp.StatusCode == 401 {                              // token expired: refresh once
        req.Header.Set("Authorization", "Bearer "+freshToken(botUser, botPass))
        resp = do(req)
    }
    return resp
}
```

## Honest limitations

- **No trigger-time form inside Concourse.** The `+` button in the Concourse
  UI still triggers immediately with no inputs; the only "form" is whatever
  the relay serves on its own port. Operators live in two UIs.
- **Eager interpolation bakes values into visible config.** `((branch))` is
  substituted at set-pipeline time, so the value is stored in — and visible
  via — `fly get-pipeline` for every instance. Fine for branch names; bad the
  moment someone routes anything sensitive through it. There are no declared
  defaults or descriptions, and no per-build audit trail of "who triggered
  with what" beyond relay logs.
- **One pipeline instance per var combination.** Every distinct value mints a
  new instance with its own build history, dashboard entry, and scheduling
  overhead. Without disciplined archiving (the PR-close hook, plus periodic
  GC for instances whose close event was missed) the instance group grows
  without bound. Rerunning an old build after its instance is archived is
  awkward.
- **The relay holds credentials and becomes infrastructure.** It stores a bot
  password (or token) with `member`-level access and the GitHub HMAC secret,
  must be deployed/monitored/patched, and is a single point of failure
  between GitHub and CI. The POC's webhook endpoint keeps token verification
  and var validation inside the ATC instead.

## Other stock-Concourse alternatives, briefly

- **Params-file resource + `load_var`.** Commit/PUT a JSON/YAML params file
  somewhere (git branch, s3 key), have the job `get` it and `load_var` each
  value, reference them as `((.:var))`. This gets *lazy* runtime resolution —
  same mechanism the POC builds on — but triggering means writing a file to
  an external store, there's no UI/API surface for it, no declared defaults
  or validation, and the "trigger payload" is versioned resource state rather
  than build metadata.
- **`fly execute -v`.** One-off task runs already accept `-v` overrides. Fine
  for ad-hoc experiments by someone with fly installed, but it bypasses the
  pipeline entirely: no job history, no webhook path, no UI, and the task
  config comes from the invoker's disk rather than the pipeline definition.
