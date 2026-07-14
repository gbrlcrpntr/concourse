package commands

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/concourse/concourse/atc"
	"github.com/concourse/concourse/fly/commands/internal/flaghelpers"
	"github.com/concourse/concourse/fly/eventstream"
	"github.com/concourse/concourse/fly/rc"
	"github.com/concourse/concourse/fly/ui"
	"github.com/concourse/concourse/go-concourse/concourse"
)

type TriggerJobCommand struct {
	Job     flaghelpers.JobFlag                `short:"j" long:"job" required:"true" value-name:"PIPELINE/JOB" description:"Name of a job to trigger"`
	Var     []flaghelpers.VariablePairFlag     `short:"v" long:"var" unquote:"false" value-name:"[NAME=STRING]" description:"Specify a string value for a var declared by the job"`
	YAMLVar []flaghelpers.YAMLVariablePairFlag `short:"y" long:"yaml-var" unquote:"false" value-name:"[NAME=YAML]" description:"Specify a YAML value for a var declared by the job"`
	Watch   bool                               `short:"w" long:"watch" description:"Start watching the build output"`
	Team    flaghelpers.TeamFlag               `long:"team" description:"Name of the team to which the job belongs, if different from the target default"`
}

func (command *TriggerJobCommand) Execute(args []string) error {
	jobName := command.Job.JobName
	pipelineRef := command.Job.PipelineRef

	target, err := rc.LoadTarget(Fly.Target, Fly.Verbose)
	if err != nil {
		return err
	}

	err = target.Validate()
	if err != nil {
		return err
	}

	var (
		build atc.Build
		team  concourse.Team
	)
	team, err = command.Team.LoadTeam(target)
	if err != nil {
		return err
	}

	buildVars := map[string]any{}
	for _, pair := range command.Var {
		buildVars[pair.Ref.String()] = pair.Value
	}
	for _, pair := range command.YAMLVar {
		buildVars[pair.Ref.String()] = pair.Value
	}

	build, err = team.CreateJobBuildWithVars(pipelineRef, jobName, buildVars)
	if err != nil {
		return err
	} else {
		fmt.Printf("started %s/%s #%s\n", pipelineRef.String(), jobName, build.Name)
	}

	if len(buildVars) > 0 && len(build.TriggerVars) == 0 {
		fmt.Fprintf(ui.Stderr, "warning: the server did not record any trigger vars; it may predate job vars support\n")
	}

	if command.Watch {
		terminate := make(chan os.Signal, 1)

		go func(terminate <-chan os.Signal) {
			<-terminate
			fmt.Fprintf(ui.Stderr, "\ndetached, build is still running...\n")
			fmt.Fprintf(ui.Stderr, "re-attach to it with:\n\n")
			fmt.Fprint(ui.Stderr, "    "+ui.Embolden(fmt.Sprintf("fly -t %s watch -j %s/%s -b %s\n\n", Fly.Target, pipelineRef.String(), jobName, build.Name)))
			os.Exit(2)
		}(terminate)

		signal.Notify(terminate, syscall.SIGINT, syscall.SIGTERM)

		fmt.Println("")
		eventSource, err := target.Client().BuildEvents(fmt.Sprintf("%d", build.ID))
		if err != nil {
			return err
		}

		renderOptions := eventstream.RenderOptions{}

		exitCode := eventstream.Render(os.Stdout, eventSource, renderOptions)

		eventSource.Close()

		os.Exit(exitCode)
	}

	return nil
}
