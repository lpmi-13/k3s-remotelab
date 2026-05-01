package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// StaleJob modifies the migration Job template so the PreSync migration fails.
// ArgoCD cannot complete the sync while the hook Job is failing.
type StaleJob struct{}

func (s *StaleJob) Name() string {
	return "stale-job"
}

func (s *StaleJob) Description() string {
	return "Modifies the migration Job template so the PreSync migration hook fails, " +
		"blocking the ArgoCD sync."
}

func (s *StaleJob) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: update migration job configuration",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(MigrateJobFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", MigrateJobFile, err)
			}

			content := string(data)

			marker := "          set -e\n          echo \"Running Django migrations...\""
			injection := "          set -e\n          echo \"ERROR: migration dependency check failed\"\n          exit 1\n          echo \"Running Django migrations...\""

			modified := strings.Replace(content, marker, injection, 1)

			if modified == content {
				return fmt.Errorf("could not find insertion point in migrate-job.yaml")
			}

			return w.WriteFile(MigrateJobFile, []byte(modified))
		},
	)
}

func (s *StaleJob) Revert(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: restore migration job configuration",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(MigrateJobFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", MigrateJobFile, err)
			}

			content := string(data)

			injection := "          set -e\n          echo \"ERROR: migration dependency check failed\"\n          exit 1\n          echo \"Running Django migrations...\""
			marker := "          set -e\n          echo \"Running Django migrations...\""

			modified := strings.Replace(content, injection, marker, 1)
			return w.WriteFile(MigrateJobFile, []byte(modified))
		},
	)
}

func (s *StaleJob) Explanation() string {
	return "The PreSync migration Job was changed to fail before running Django migrations. " +
		"ArgoCD waits for hook Jobs to complete before applying the rest of the sync, so the " +
		"application stays stuck in a failed/progressing sync state. The fix is to remove the " +
		"failing command from the migration Job template and sync again."
}

func (s *StaleJob) DiagnoseCommands() []string {
	return []string{
		"kubectl get jobs -n applications",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.operationState.message}'",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'",
		"kubectl describe job -n applications -l app.kubernetes.io/component=migration",
	}
}
