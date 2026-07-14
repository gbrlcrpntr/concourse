package testflight_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"
)

var _ = Describe("Job trigger-time vars", func() {
	BeforeEach(func() {
		setAndUnpausePipeline(
			"fixtures/job-vars.yml",
			"-v", "default_branch=main",
			"-v", "default_label=original",
		)
	})

	It("resolves declared defaults when triggered without overrides", func(ctx SpecContext) {
		watch := fly("trigger-job", "-j", inPipeline("echo-vars"), "-w")
		Expect(watch).To(gbytes.Say("branch=main"))
		Expect(watch).To(gbytes.Say("label=original"))
		Expect(watch).To(gbytes.Say("count=1"))
		Expect(watch).To(gbytes.Say("dry_run=false"))
		Expect(watch).To(gbytes.Say("deploy_env=dev"))
	}, DefaultSpecTimeout)

	It("resolves per-build overrides passed via trigger-job -v and -y", func(ctx SpecContext) {
		watch := fly(
			"trigger-job", "-j", inPipeline("echo-vars"),
			"-v", "branch=feature-x",
			"-v", "deploy_env=prod",
			"-y", "count=3",
			"-y", "dry_run=true",
			"-w",
		)
		Expect(watch).To(gbytes.Say("branch=feature-x"))
		Expect(watch).To(gbytes.Say("count=3"))
		Expect(watch).To(gbytes.Say("dry_run=true"))
		Expect(watch).To(gbytes.Say("deploy_env=prod"))
	}, DefaultSpecTimeout)

	It("rejects trigger values that do not match their declarations", func(ctx SpecContext) {
		trigger := flyUnsafe(
			"trigger-job", "-j", inPipeline("echo-vars"),
			"-y", "count=not-a-number",
		)

		Expect(trigger).To(gexec.Exit(1))
		Expect(trigger.Err).To(gbytes.Say("var 'count' expects number, got string"))
		Expect(flyTable("builds", "-j", inPipeline("echo-vars"))).To(BeEmpty())
	}, DefaultSpecTimeout)

	It("copies overrides but resolves current defaults on rerun", func(ctx SpecContext) {
		By("triggering a build with an overridden var")
		watch := fly("trigger-job", "-j", inPipeline("echo-vars"), "-v", "branch=feature-x", "-w")
		Expect(watch).To(gbytes.Say("branch=feature-x"))
		Expect(watch).To(gbytes.Say("label=original"))

		By("changing an unoverridden default in the current job config")
		setPipeline(
			"fixtures/job-vars.yml",
			"-v", "default_branch=changed-but-overridden",
			"-v", "default_label=updated",
		)

		By("rerunning that build")
		rerun := fly("rerun-build", "-j", inPipeline("echo-vars"), "-b", "1", "-w")
		Expect(rerun).To(gbytes.Say("branch=feature-x"))
		Expect(rerun).To(gbytes.Say("label=updated"))

		By("confirming the rerun copied only the override and read current defaults")
		watch = waitForBuildAndWatch("echo-vars", "1.1")
		Eventually(watch).Should(gbytes.Say("branch=feature-x"))
		Eventually(watch).Should(gbytes.Say("label=updated"))
	}, DefaultSpecTimeout)

	Describe("triggering via the job webhook endpoint", func() {
		var webhookURL string

		BeforeEach(func() {
			webhookURL = fmt.Sprintf(
				"%s/api/v1/teams/%s/pipelines/%s/jobs/echo-vars/builds/webhook",
				config.ATCURL, teamName, pipelineName,
			)
		})

		postWebhook := func(token string, payload string) (*http.Response, []byte) {
			url := webhookURL + "?webhook_token=" + token + "&name=github-pr"
			resp, err := http.Post(url, "application/json", bytes.NewBufferString(payload))
			Expect(err).ToNot(HaveOccurred())

			body, err := io.ReadAll(resp.Body)
			Expect(err).ToNot(HaveOccurred())
			Expect(resp.Body.Close()).To(Succeed())

			return resp, body
		}

		It("creates a build with vars extracted from the payload", func(ctx SpecContext) {
			By("posting a payload that matches the filter")
			resp, body := postWebhook("wh-secret", `{
				"action": "opened",
				"pull_request": {
					"head": {
						"ref": "pr-branch"
					}
				}
			}`)
			Expect(resp.StatusCode).To(Equal(http.StatusCreated), "Body: "+string(body))

			var build struct {
				Name string `json:"name"`
			}
			Expect(json.Unmarshal(body, &build)).To(Succeed())
			Expect(build.Name).ToNot(BeEmpty())

			By("watching the created build")
			watch := waitForBuildAndWatch("echo-vars", build.Name)
			Eventually(watch).Should(gbytes.Say("branch=pr-branch"))

			By("posting a payload that does not match the filter")
			resp, body = postWebhook("wh-secret", `{
				"action": "closed",
				"pull_request": {
					"head": {
						"ref": "pr-branch"
					}
				}
			}`)
			Expect(resp.StatusCode).To(Equal(http.StatusOK), "Body: "+string(body))
			Expect(string(body)).To(ContainSubstring(`"skipped": true`))

			By("confirming the filtered-out payload did not create a build")
			builds := flyTable("builds", "-j", inPipeline("echo-vars"))
			Expect(builds).To(HaveLen(1))

			By("rejecting a request with the wrong token")
			resp, _ = postWebhook("bogus-token", `{
				"action": "opened",
				"pull_request": {
					"head": {
						"ref": "pr-branch"
					}
				}
			}`)
			Expect(resp.StatusCode).To(Equal(http.StatusUnauthorized))
		}, DefaultSpecTimeout)

		It("rejects payloads larger than one MiB", func(ctx SpecContext) {
			payload := fmt.Sprintf(
				`{"action":"opened","padding":"%s"}`,
				strings.Repeat("x", (1<<20)+1),
			)

			resp, body := postWebhook("wh-secret", payload)
			Expect(resp.StatusCode).To(Equal(http.StatusBadRequest), "Body: "+string(body))
			Expect(string(body)).To(ContainSubstring("request body too large"))
			Expect(flyTable("builds", "-j", inPipeline("echo-vars"))).To(BeEmpty())
		}, DefaultSpecTimeout)
	})
})
