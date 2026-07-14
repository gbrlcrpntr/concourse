package testflight_test

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
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

		postWebhook := func(secret, deliveryID, payload string) (*http.Response, []byte) {
			mac := hmac.New(sha256.New, []byte(secret))
			_, err := mac.Write([]byte(payload))
			Expect(err).ToNot(HaveOccurred())

			request, err := http.NewRequest(
				http.MethodPost,
				webhookURL+"?name=github-pr",
				bytes.NewBufferString(payload),
			)
			Expect(err).ToNot(HaveOccurred())
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac.Sum(nil)))
			request.Header.Set("X-GitHub-Delivery", deliveryID)

			resp, err := http.DefaultClient.Do(request)
			Expect(err).ToNot(HaveOccurred())

			body, err := io.ReadAll(resp.Body)
			Expect(err).ToNot(HaveOccurred())
			Expect(resp.Body.Close()).To(Succeed())

			return resp, body
		}

		It("creates a build with vars extracted from the payload", func(ctx SpecContext) {
			By("posting a payload that matches the filter")
			payload := `{
				"action": "synchronize",
				"number": 42,
				"pull_request": {
					"head": {
						"ref": "pr-branch",
						"sha": "abc123"
					},
					"base": {
						"ref": "main"
					}
				}
			}`
			resp, body := postWebhook("wh-secret", "delivery-123", payload)
			Expect(resp.StatusCode).To(Equal(http.StatusCreated), "Body: "+string(body))

			var build struct {
				Name string `json:"name"`
			}
			Expect(json.Unmarshal(body, &build)).To(Succeed())
			Expect(build.Name).ToNot(BeEmpty())

			By("watching the created build")
			watch := waitForBuildAndWatch("echo-vars", build.Name)
			Eventually(watch).Should(gbytes.Say("branch=pr-branch"))
			Eventually(watch).Should(gbytes.Say("pr_number=42"))
			Eventually(watch).Should(gbytes.Say("head_sha=abc123"))
			Eventually(watch).Should(gbytes.Say("base_ref=main"))

			By("returning the existing build for a redelivery")
			resp, duplicateBody := postWebhook("wh-secret", "delivery-123", payload)
			Expect(resp.StatusCode).To(Equal(http.StatusOK), "Body: "+string(duplicateBody))
			var duplicateBuild struct {
				Name string `json:"name"`
			}
			Expect(json.Unmarshal(duplicateBody, &duplicateBuild)).To(Succeed())
			Expect(duplicateBuild.Name).To(Equal(build.Name))

			By("posting a payload that does not match the filter")
			resp, body = postWebhook("wh-secret", "delivery-closed", `{
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

			By("rejecting a request with the wrong signing secret")
			resp, _ = postWebhook("bogus-secret", "delivery-invalid", `{
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

			resp, body := postWebhook("wh-secret", "delivery-large", payload)
			Expect(resp.StatusCode).To(Equal(http.StatusBadRequest), "Body: "+string(body))
			Expect(string(body)).To(ContainSubstring("request body too large"))
			Expect(flyTable("builds", "-j", inPipeline("echo-vars"))).To(BeEmpty())
		}, DefaultSpecTimeout)
	})
})
