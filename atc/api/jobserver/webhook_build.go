package jobserver

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"code.cloudfoundry.org/lager/v3"
	"github.com/concourse/concourse/atc"
	"github.com/concourse/concourse/atc/api/present"
	"github.com/concourse/concourse/atc/creds"
	"github.com/concourse/concourse/atc/db"
	"github.com/concourse/concourse/vars"
	"github.com/tedsuo/rata"
)

const webhookPayloadLimit = 1 << 20 // 1 MiB

// CreateJobBuildWebhook triggers a build of a job from an inbound webhook,
// extracting the job's declared vars from the JSON payload according to the
// matching trigger_webhooks entry in the job's config. Requests are
// authenticated by the webhook_token query param, like resource check
// webhooks.
func (s *Server) CreateJobBuildWebhook(pipeline db.Pipeline) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		jobName := rata.Param(r, "job_name")
		hookName := r.URL.Query().Get("name")
		webhookToken := r.URL.Query().Get("webhook_token")

		logger := s.logger.Session("create-job-build-webhook", lager.Data{
			"job":     jobName,
			"webhook": hookName,
		})

		if webhookToken == "" {
			logger.Info("no-webhook-token")
			writeJSONError(w, http.StatusBadRequest, "missing webhook_token")
			return
		}

		job, found, err := pipeline.Job(jobName)
		if err != nil {
			logger.Error("failed-to-get-job", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		if !found {
			w.WriteHeader(http.StatusNotFound)
			return
		}

		config, err := job.Config()
		if err != nil {
			logger.Error("failed-to-get-job-config", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		hook, err := selectWebhook(config.TriggerWebhooks, hookName)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}

		secretsParams := creds.SecretLookupParams{
			Team:         pipeline.TeamName(),
			Pipeline:     pipeline.Name(),
			InstanceVars: pipeline.InstanceVars(),
			Job:          jobName,
		}

		variables, err := pipeline.Variables(logger, s.secretManager, s.varSourcePool, secretsParams)
		if err != nil {
			logger.Error("failed-to-create-var-sources", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		token, err := creds.NewString(variables, hook.Token).Evaluate()
		if err != nil {
			logger.Error("failed-to-evaluate-webhook-token", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		if token != webhookToken {
			logger.Info("invalid-token")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		var payload map[string]any
		err = json.NewDecoder(http.MaxBytesReader(w, r.Body, webhookPayloadLimit)).Decode(&payload)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, fmt.Sprintf("malformed payload: %s", err))
			return
		}

		if !matchesFilter(payload, hook.Filter) {
			logger.Debug("payload-filtered-out")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, `{"skipped": true}`)
			return
		}

		triggerVars, err := extractVars(payload, hook.VarMapping, config.Vars)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}

		err = config.Vars.Validate(triggerVars)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}

		build, err := job.CreateBuildWithVars("webhook:"+hook.Name, triggerVars)
		if err != nil {
			logger.Error("failed-to-create-job-build", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusCreated)

		err = json.NewEncoder(w).Encode(present.Build(build, job, nil))
		if err != nil {
			logger.Error("failed-to-encode-build", err)
			w.WriteHeader(http.StatusInternalServerError)
		}
	})
}

// selectWebhook picks the trigger_webhooks entry named by the request, or the
// sole configured entry when no name is given.
func selectWebhook(hooks []atc.TriggerWebhook, name string) (atc.TriggerWebhook, error) {
	if len(hooks) == 0 {
		return atc.TriggerWebhook{}, fmt.Errorf("job has no trigger_webhooks configured")
	}

	if name == "" {
		if len(hooks) == 1 {
			return hooks[0], nil
		}
		return atc.TriggerWebhook{}, fmt.Errorf("multiple trigger_webhooks configured; specify one with the 'name' query param")
	}

	for _, hook := range hooks {
		if hook.Name == name {
			return hook, nil
		}
	}

	return atc.TriggerWebhook{}, fmt.Errorf("no trigger_webhook named '%s'", name)
}

// matchesFilter reports whether every filter entry, addressed as a dot-path
// into the payload, equals its expected value.
func matchesFilter(payload map[string]any, filter map[string]any) bool {
	for path, expected := range filter {
		actual, found := traversePayload(payload, path)
		if !found {
			return false
		}
		expectedJSON, err := json.Marshal(expected)
		if err != nil {
			return false
		}
		actualJSON, err := json.Marshal(actual)
		if err != nil {
			return false
		}
		if string(expectedJSON) != string(actualJSON) {
			return false
		}
	}
	return true
}

// extractVars maps payload fields onto declared vars via each mapping's
// dot-path. A missing path is tolerated for optional vars so their current
// default (if any) can be resolved when the build runs.
func extractVars(payload map[string]any, mapping map[string]string, declared atc.JobVars) (map[string]any, error) {
	extracted := map[string]any{}
	for varName, path := range mapping {
		val, found := traversePayload(payload, path)
		if !found {
			if decl, ok := declared[varName]; ok && !decl.Required {
				continue
			}
			return nil, fmt.Errorf("payload has no value at '%s' for var '%s'", path, varName)
		}
		extracted[varName] = val
	}
	return extracted, nil
}

func traversePayload(payload map[string]any, path string) (any, bool) {
	val, err := vars.Traverse(payload, path, strings.Split(path, "."))
	if err != nil {
		return nil, false
	}
	return val, true
}
