package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// StaleJob modifies the migration Job template by adding an environment variable.
// Since Kubernetes Jobs are immutable once created, ArgoCD cannot update the
// existing Job and will report a sync error. The user must delete the old Job
// so ArgoCD can recreate it with the new spec.
type StaleJob struct{}

func (s *StaleJob) Name() string {
	return "stale-job"
}

func (s *StaleJob) Description() string {
	return "Modifies the migration Job template (adds an env var), causing ArgoCD to fail " +
		"when trying to update the immutable Job resource. User must delete the old Job."
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

			// Add an extra environment variable to the migrate container.
			// We insert it just after the "command:" line in the migrate container.
			// The new env var is harmless but changes the Job spec, making it immutable-incompatible.
			marker := "        command:\n        - /bin/bash\n        - -c\n        - |"
			injection := "        env:\n" +
				"        - name: MIGRATION_TIMEOUT\n" +
				"          value: \"300\"\n" +
				"        command:\n        - /bin/bash\n        - -c\n        - |"

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

			// Remove the injected env block.
			injection := "        env:\n" +
				"        - name: MIGRATION_TIMEOUT\n" +
				"          value: \"300\"\n" +
				"        command:"
			marker := "        command:"

			modified := strings.Replace(content, injection, marker, 1)
			return w.WriteFile(MigrateJobFile, []byte(modified))
		},
	)
}

func (s *StaleJob) Explanation() string {
	return "A new environment variable (MIGRATION_TIMEOUT) was added to the migration Job " +
		"template. Kubernetes Jobs are immutable: once created, their spec cannot be changed. " +
		"When ArgoCD tried to sync the updated Job spec, it failed because the existing Job " +
		"could not be patched. The fix is to delete the old Job (kubectl delete job " +
		"django-migrate-latest -n applications) so ArgoCD can create a fresh one with the " +
		"updated spec, or revert the change in git."
}

func (s *StaleJob) DiagnoseCommands() []string {
	return []string{
		"kubectl get jobs -n applications",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.operationState.message}'",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'",
		"kubectl describe job -n applications -l app.kubernetes.io/component=migration",
	}
}
