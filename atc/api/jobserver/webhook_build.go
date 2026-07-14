package jobserver

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"code.cloudfoundry.org/lager/v3"
	"github.com/concourse/concourse/atc"
	"github.com/concourse/concourse/atc/api/present"
	"github.com/concourse/concourse/atc/creds"
	"github.com/concourse/concourse/atc/db"
	"github.com/concourse/concourse/vars"
	"github.com/tedsuo/rata"
)

const (
	webhookPayloadLimit    = 1 << 20 // 1 MiB
	webhookDeliveryIDLimit = 256
)

// CreateJobBuildWebhook triggers a build of a job from an inbound webhook,
// extracting the job's declared vars from the JSON payload according to the
// matching trigger_webhooks entry in the job's config. Requests are
// authenticated by either the webhook_token query param, like resource check
// webhooks, or a configured HMAC-SHA256 signature.
func (s *Server) CreateJobBuildWebhook(pipeline db.Pipeline) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		jobName := rata.Param(r, "job_name")
		hookName := r.URL.Query().Get("name")

		logger := s.logger.Session("create-job-build-webhook", lager.Data{
			"job":     jobName,
			"webhook": hookName,
		})

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

		requestBody, err := io.ReadAll(http.MaxBytesReader(w, r.Body, webhookPayloadLimit))
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, fmt.Sprintf("malformed payload: %s", err))
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

		if hook.Token != "" {
			webhookToken := r.URL.Query().Get("webhook_token")
			if webhookToken == "" {
				logger.Info("no-webhook-token")
				writeJSONError(w, http.StatusBadRequest, "missing webhook_token")
				return
			}

			token, err := creds.NewString(variables, hook.Token).Evaluate()
			if err != nil {
				logger.Error("failed-to-evaluate-webhook-token", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}

			if !hmac.Equal([]byte(token), []byte(webhookToken)) {
				logger.Info("invalid-token")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
		} else if hook.Authentication != nil && hook.Authentication.HMACSHA256 != nil {
			hmacConfig := hook.Authentication.HMACSHA256
			secret, err := creds.NewString(variables, hmacConfig.Secret).Evaluate()
			if err != nil {
				logger.Error("failed-to-evaluate-webhook-hmac-secret", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}

			if !validHMACSHA256(requestBody, r.Header.Get(hmacConfig.Header), secret, hmacConfig.Prefix) {
				logger.Info("invalid-hmac-signature")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
		} else {
			logger.Error("invalid-webhook-authentication", fmt.Errorf("no authentication configured"))
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		createdBy := "webhook:" + hook.Name
		deliveryID := ""
		if hook.DeliveryID != nil {
			deliveryID = r.Header.Get(hook.DeliveryID.Header)
			if deliveryID == "" {
				writeJSONError(w, http.StatusBadRequest, fmt.Sprintf("missing delivery ID header %s", hook.DeliveryID.Header))
				return
			}
			if len(deliveryID) > webhookDeliveryIDLimit || !utf8.ValidString(deliveryID) {
				writeJSONError(w, http.StatusBadRequest, "delivery ID must be valid UTF-8 and at most 256 bytes")
				return
			}

			existingBuild, found, err := job.BuildByTriggerID(createdBy, deliveryID)
			if err != nil {
				logger.Error("failed-to-find-webhook-delivery", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			if found {
				logger.Info("duplicate-delivery")
				w.WriteHeader(http.StatusOK)
				err = json.NewEncoder(w).Encode(present.Build(existingBuild, job, nil))
				if err != nil {
					logger.Error("failed-to-encode-build", err)
				}
				return
			}
		}

		var payload map[string]any
		err = json.Unmarshal(requestBody, &payload)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, fmt.Sprintf("malformed payload: %s", err))
			return
		}
		if payload == nil {
			writeJSONError(w, http.StatusBadRequest, "malformed payload: expected a JSON object")
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

		var build db.Build
		created := true
		if hook.DeliveryID != nil {
			build, created, err = job.CreateBuildWithVarsAndTriggerID(createdBy, triggerVars, deliveryID)
		} else {
			build, err = job.CreateBuildWithVars(createdBy, triggerVars)
		}
		if err != nil {
			logger.Error("failed-to-create-job-build", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		if created {
			w.WriteHeader(http.StatusCreated)
		} else {
			logger.Info("duplicate-delivery")
			w.WriteHeader(http.StatusOK)
		}

		err = json.NewEncoder(w).Encode(present.Build(build, job, nil))
		if err != nil {
			logger.Error("failed-to-encode-build", err)
			w.WriteHeader(http.StatusInternalServerError)
		}
	})
}

func validHMACSHA256(payload []byte, signature, secret, prefix string) bool {
	if !strings.HasPrefix(signature, prefix) {
		return false
	}

	providedMAC, err := hex.DecodeString(strings.TrimPrefix(signature, prefix))
	if err != nil {
		return false
	}

	expectedMAC := hmac.New(sha256.New, []byte(secret))
	_, _ = expectedMAC.Write(payload)
	return hmac.Equal(providedMAC, expectedMAC.Sum(nil))
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
		if !matchesFilterValue(actual, expected) {
			return false
		}
	}
	return true
}

func matchesFilterValue(actual, expected any) bool {
	if condition, ok := expected.(map[string]any); ok {
		if oneOf, ok := condition["one_of"].([]any); ok && len(condition) == 1 {
			for _, option := range oneOf {
				if jsonValuesEqual(actual, option) {
					return true
				}
			}
			return false
		}
	}

	return jsonValuesEqual(actual, expected)
}

func jsonValuesEqual(left, right any) bool {
	leftJSON, err := json.Marshal(left)
	if err != nil {
		return false
	}
	rightJSON, err := json.Marshal(right)
	if err != nil {
		return false
	}
	return string(leftJSON) == string(rightJSON)
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
