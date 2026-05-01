package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// PVCIncompatible changes the PostgreSQL init container image to an incompatible
// major version (postgres:16). The existing PVC contains data files formatted
// for the previous PostgreSQL version (15). When postgres:16 tries to start
// with the old data directory, it crashes because the data format is incompatible
// between major versions. The user must delete the PVC to allow a fresh start.
type PVCIncompatible struct{}

func (s *PVCIncompatible) Name() string {
	return "pvc-incompatible"
}

func (s *PVCIncompatible) Description() string {
	return "Changes the PostgreSQL init container image from postgres:15 to postgres:16 in " +
		"the Deployment and Job templates. The existing PVC data is incompatible with the new " +
		"major version, causing CrashLoopBackOff."
}

func (s *PVCIncompatible) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: upgrade postgresql version",
		func(w *git.WorkDir) error {
			// Update the Deployment template.
			deployData, err := w.ReadFile(DeploymentFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", DeploymentFile, err)
			}

			deployContent := string(deployData)
			deployModified := strings.ReplaceAll(deployContent, "image: postgres:15", "image: postgres:16")
			if deployModified == deployContent {
				return fmt.Errorf("postgres:15 image reference not found in deployment.yaml")
			}

			if err := w.WriteFile(DeploymentFile, []byte(deployModified)); err != nil {
				return fmt.Errorf("failed to write %s: %w", DeploymentFile, err)
			}

			// Update the migration Job template.
			jobData, err := w.ReadFile(MigrateJobFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", MigrateJobFile, err)
			}

			jobContent := string(jobData)
			jobModified := strings.ReplaceAll(jobContent, "image: postgres:15", "image: postgres:16")

			if err := w.WriteFile(MigrateJobFile, []byte(jobModified)); err != nil {
				return fmt.Errorf("failed to write %s: %w", MigrateJobFile, err)
			}

			return nil
		},
	)
}

func (s *PVCIncompatible) Revert(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"revert: restore postgresql version",
		func(w *git.WorkDir) error {
			// Restore postgres:15 in the Deployment template.
			deployData, err := w.ReadFile(DeploymentFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", DeploymentFile, err)
			}
			deployContent := string(deployData)
			deployModified := strings.ReplaceAll(deployContent, "image: postgres:16", "image: postgres:15")
			if err := w.WriteFile(DeploymentFile, []byte(deployModified)); err != nil {
				return err
			}

			// Restore postgres:15 in the Job template.
			jobData, err := w.ReadFile(MigrateJobFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", MigrateJobFile, err)
			}
			jobContent := string(jobData)
			jobModified := strings.ReplaceAll(jobContent, "image: postgres:16", "image: postgres:15")
			return w.WriteFile(MigrateJobFile, []byte(jobModified))
		},
	)
}

func (s *PVCIncompatible) Explanation() string {
	return "The PostgreSQL init container image was changed from postgres:15 to postgres:16. " +
		"PostgreSQL data files are not compatible across major versions. The existing PVC " +
		"contains data formatted for PostgreSQL 15, which PostgreSQL 16 cannot read, causing " +
		"the init container to crash with CrashLoopBackOff. The fix involves either: " +
		"(1) reverting to postgres:15 in the templates, or (2) deleting the PVC " +
		"(kubectl delete pvc -n applications -l app=postgresql) and letting it recreate " +
		"with a fresh database, then re-running migrations."
}

func (s *PVCIncompatible) DiagnoseCommands() []string {
	return []string{
		"kubectl get pods -n applications",
		"kubectl describe pod -n applications -l app=django",
		"kubectl logs -n applications -l app=django -c wait-for-db --tail=20",
		"kubectl get pvc -n applications",
		"kubectl get events -n applications --sort-by=.lastTimestamp | grep -i crash",
	}
}
