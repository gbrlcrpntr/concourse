package atc

import (
	"fmt"
	"sort"
	"strings"
)

// JobVars declares the build-local variables a job accepts at trigger time,
// keyed by var name. Declared vars are resolvable in the job's steps as
// ((.:name)). Defaults may be overridden per build via the create-build API
// or a configured trigger webhook.
type JobVars map[string]JobVarConfig

// JobVarType identifies the value type accepted by a declared job var.
type JobVarType string

const (
	JobVarTypeString  JobVarType = "string"
	JobVarTypeNumber  JobVarType = "number"
	JobVarTypeBoolean JobVarType = "boolean"
	JobVarTypeEnum    JobVarType = "enum"
)

// JobVarConfig declares the type, validation, and presentation metadata for a
// build-local variable accepted by a job.
type JobVarConfig struct {
	Type        JobVarType `json:"type,omitempty"`
	Options     []string   `json:"options,omitempty"`
	Default     any        `json:"default,omitempty"`
	Description string     `json:"description,omitempty"`
	Required    bool       `json:"required,omitempty"`
}

// TriggerWebhook configures an inbound webhook that creates a build of the
// job, extracting var values from the JSON request payload.
type TriggerWebhook struct {
	Name string `json:"name"`

	// Token authenticates webhook requests via the webhook_token query
	// param. It may be a ((var)) reference resolved through the pipeline's
	// var sources.
	Token string `json:"token"`

	// Filter maps dot-paths into the payload to expected values; if any
	// entry does not match, the webhook is ignored.
	Filter map[string]any `json:"filter,omitempty"`

	// VarMapping maps declared var names to dot-paths into the payload.
	VarMapping map[string]string `json:"var_mapping,omitempty"`
}

// Validate checks per-build var overrides against the declared vars,
// rejecting undeclared names and enforcing required vars.
func (v JobVars) Validate(overrides map[string]any) error {
	var undeclared []string
	for name := range overrides {
		if _, ok := v[name]; !ok {
			undeclared = append(undeclared, name)
		}
	}
	if len(undeclared) > 0 {
		sort.Strings(undeclared)
		return fmt.Errorf("undeclared var(s): %s", strings.Join(undeclared, ", "))
	}

	var nullOverrides []string
	for name, val := range overrides {
		if val == nil {
			nullOverrides = append(nullOverrides, name)
		}
	}
	if len(nullOverrides) > 0 {
		sort.Strings(nullOverrides)
		if len(nullOverrides) == 1 {
			return fmt.Errorf("var '%s' must not be null; omit it instead", nullOverrides[0])
		}

		return fmt.Errorf("vars %s must not be null; omit them instead", quoteNames(nullOverrides))
	}

	var missing []string
	for name, decl := range v {
		if !decl.Required || decl.Default != nil {
			continue
		}
		if val, ok := overrides[name]; !ok || val == nil {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("missing required var(s): %s", strings.Join(missing, ", "))
	}

	for name, val := range overrides {
		decl := v[name]
		if err := decl.ValidateValue(fmt.Sprintf("var '%s'", name), val); err != nil {
			return err
		}
	}

	return nil
}

// Merge lays the given overrides over the declared defaults, returning the
// effective var values for a build. Vars with neither a default nor an
// override are omitted.
func (v JobVars) Merge(overrides map[string]any) map[string]any {
	merged := map[string]any{}
	for name, decl := range v {
		if decl.Default != nil {
			merged[name] = decl.Default
		}
	}
	for name, val := range overrides {
		if val != nil {
			merged[name] = val
		}
	}
	return merged
}

// Effective returns the declared type, defaulting an omitted type to string.
func (t JobVarType) Effective() JobVarType {
	if t == "" {
		return JobVarTypeString
	}

	return t
}

// Valid reports whether the type is supported.
func (t JobVarType) Valid() bool {
	switch t.Effective() {
	case JobVarTypeString, JobVarTypeNumber, JobVarTypeBoolean, JobVarTypeEnum:
		return true
	default:
		return false
	}
}

// ValidateDefinition validates the relationships between a declaration's
// type, options, and default value.
func (c JobVarConfig) ValidateDefinition(identifier string) []string {
	var errorMessages []string

	if !c.Type.Valid() {
		errorMessages = append(
			errorMessages,
			fmt.Sprintf("%s has unsupported type '%s' (expected one of: string, number, boolean, enum)", identifier, c.Type),
		)
		return errorMessages
	}

	switch c.Type.Effective() {
	case JobVarTypeEnum:
		if len(c.Options) == 0 {
			errorMessages = append(errorMessages, identifier+" has type enum but no options")
		}
	default:
		if len(c.Options) > 0 {
			errorMessages = append(errorMessages, identifier+".options is only valid for type enum")
		}
	}

	if c.Default != nil {
		if err := c.ValidateValue(identifier+" default", c.Default); err != nil {
			errorMessages = append(errorMessages, err.Error())
		}
	}

	return errorMessages
}

// ValidateValue checks a concrete value against the declaration.
func (c JobVarConfig) ValidateValue(context string, value any) error {
	if value == nil {
		return nil
	}

	switch c.Type.Effective() {
	case JobVarTypeString:
		if _, ok := value.(string); !ok {
			return fmt.Errorf("%s expects string, got %s", context, jobVarValueType(value))
		}
	case JobVarTypeNumber:
		if !isJobVarNumber(value) {
			return fmt.Errorf("%s expects number, got %s", context, jobVarValueType(value))
		}
	case JobVarTypeBoolean:
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s expects boolean, got %s", context, jobVarValueType(value))
		}
	case JobVarTypeEnum:
		str, ok := value.(string)
		if !ok {
			return fmt.Errorf("%s expects enum string, got %s", context, jobVarValueType(value))
		}
		if !containsString(c.Options, str) {
			return fmt.Errorf("%s must be one of: %s", context, strings.Join(c.Options, ", "))
		}
	}

	return nil
}

func isJobVarNumber(value any) bool {
	switch value.(type) {
	case float64, float32, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return true
	default:
		return false
	}
}

func jobVarValueType(value any) string {
	switch value.(type) {
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64, float32, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return "number"
	default:
		return fmt.Sprintf("%T", value)
	}
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}

	return false
}

func quoteNames(values []string) string {
	quoted := make([]string, len(values))
	for i, value := range values {
		quoted[i] = fmt.Sprintf("'%s'", value)
	}

	return strings.Join(quoted, ", ")
}
