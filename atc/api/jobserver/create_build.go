package jobserver

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/concourse/concourse/atc"
	"github.com/concourse/concourse/atc/api/accessor"
	"github.com/concourse/concourse/atc/api/present"
	"github.com/concourse/concourse/atc/db"
)

func (s *Server) CreateJobBuild(pipeline db.Pipeline) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		logger := s.logger.Session("create-job-build")

		jobName := r.FormValue(":job_name")

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

		if job.DisableManualTrigger() {
			w.WriteHeader(http.StatusConflict)
			return
		}

		var body atc.CreateJobBuildRequestBody
		if r.ContentLength != 0 {
			err = json.NewDecoder(r.Body).Decode(&body)
			if err != nil {
				writeJSONError(w, http.StatusBadRequest, fmt.Sprintf("malformed request body: %s", err))
				return
			}
		}

		config, err := job.Config()
		if err != nil {
			logger.Error("failed-to-get-job-config", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		err = config.Vars.Validate(body.Vars)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}

		acc := accessor.GetAccessor(r)
		build, err := job.CreateBuildWithVars(acc.UserInfo().DisplayUserId, body.Vars)
		if err != nil {
			logger.Error("failed-to-create-job-build", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		err = json.NewEncoder(w).Encode(present.Build(build, job, acc))
		if err != nil {
			logger.Error("failed-to-encode-build", err)
			w.WriteHeader(http.StatusInternalServerError)
		}
	})
}
