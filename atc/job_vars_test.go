package atc_test

import (
	"github.com/concourse/concourse/atc"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("JobVars", func() {
	vars := atc.JobVars{
		"branch":      {Default: "main"},
		"dry_run":     {Type: atc.JobVarTypeBoolean, Default: false},
		"environment": {Type: atc.JobVarTypeEnum, Options: []string{"dev", "prod"}, Required: true},
		"replicas":    {Type: atc.JobVarTypeNumber, Default: 3},
	}

	Describe("Validate", func() {
		It("accepts overrides for declared vars", func() {
			err := vars.Validate(map[string]any{
				"branch":      "feature-x",
				"dry_run":     true,
				"environment": "prod",
				"replicas":    5,
			})
			Expect(err).ToNot(HaveOccurred())
		})

		It("rejects undeclared vars", func() {
			err := vars.Validate(map[string]any{
				"environment": "prod",
				"bogus":       "x",
				"also-bogus":  "y",
			})
			Expect(err).To(MatchError("undeclared var(s): also-bogus, bogus"))
		})

		It("rejects missing required vars", func() {
			err := vars.Validate(map[string]any{"branch": "feature-x"})
			Expect(err).To(MatchError("missing required var(s): environment"))
		})

		It("rejects explicit null for required vars", func() {
			err := vars.Validate(map[string]any{"environment": nil})
			Expect(err).To(MatchError("var 'environment' must not be null; omit it instead"))
		})

		It("accepts empty overrides when no vars are required", func() {
			err := atc.JobVars{"branch": {Default: "main"}}.Validate(nil)
			Expect(err).ToNot(HaveOccurred())
		})

		It("rejects explicit null for vars with defaults", func() {
			err := vars.Validate(map[string]any{"dry_run": nil, "environment": "prod"})
			Expect(err).To(MatchError("var 'dry_run' must not be null; omit it instead"))
		})

		It("rejects string values for number vars", func() {
			err := vars.Validate(map[string]any{"environment": "prod", "replicas": "5"})
			Expect(err).To(MatchError("var 'replicas' expects number, got string"))
		})

		It("rejects non-boolean values for boolean vars", func() {
			err := vars.Validate(map[string]any{"dry_run": "true", "environment": "prod"})
			Expect(err).To(MatchError("var 'dry_run' expects boolean, got string"))
		})

		It("rejects enum values outside the allowed options", func() {
			err := vars.Validate(map[string]any{"environment": "stage"})
			Expect(err).To(MatchError("var 'environment' must be one of: dev, prod"))
		})
	})

	Describe("Merge", func() {
		It("lays overrides over defaults, preserving value types", func() {
			merged := vars.Merge(map[string]any{"environment": "prod"})
			Expect(merged).To(Equal(map[string]any{
				"branch":      "main",
				"dry_run":     false,
				"environment": "prod",
				"replicas":    3,
			}))
		})

		It("lets overrides win over defaults", func() {
			merged := vars.Merge(map[string]any{"branch": "feature-x", "environment": "dev"})
			Expect(merged["branch"]).To(Equal("feature-x"))
		})

		It("ignores nil overrides so they cannot erase defaults", func() {
			merged := vars.Merge(map[string]any{"branch": nil, "environment": nil})
			Expect(merged).To(Equal(map[string]any{
				"branch":   "main",
				"dry_run":  false,
				"replicas": 3,
			}))
		})

		It("omits vars with neither default nor override", func() {
			merged := vars.Merge(nil)
			Expect(merged).ToNot(HaveKey("environment"))
		})
	})
})
