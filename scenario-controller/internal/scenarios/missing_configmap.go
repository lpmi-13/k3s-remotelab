package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// MissingConfigMap removes the appConfig section from values.yaml so the
// ConfigMap is not created, but the Deployment still references it via envFrom.
// This causes the pods to fail to start because the ConfigMap they depend on
// does not exist.
type MissingConfigMap struct{}

func (s *MissingConfigMap) Name() string {
	return "missing-configmap"
}

func (s *MissingConfigMap) Description() string {
	return "Removes the appConfig section from values.yaml so the ConfigMap is not created, " +
		"but the Deployment still references it via envFrom, causing pod startup failure."
}

func (s *MissingConfigMap) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: update application configuration",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(ValuesFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ValuesFile, err)
			}

			content := string(data)

			// Replace the appConfig section: set enabled to false and remove data.
			// We look for the appConfig block and disable it.
			if !strings.Contains(content, "appConfig:") {
				return fmt.Errorf("appConfig section not found in values.yaml")
			}

			// Replace "appConfig:\n  enabled: true" with "appConfig:\n  enabled: false"
			modified := strings.Replace(content,
				"appConfig:\n  enabled: true",
				"appConfig:\n  enabled: false",
				1,
			)

			if modified == content {
				return fmt.Errorf("failed to modify appConfig section (already disabled?)")
			}

			return w.WriteFile(ValuesFile, []byte(modified))
		},
	)
}

func (s *MissingConfigMap) Revert(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: restore application configuration",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(ValuesFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ValuesFile, err)
			}

			content := string(data)
			modified := strings.Replace(content,
				"appConfig:\n  enabled: false",
				"appConfig:\n  enabled: true",
				1,
			)

			return w.WriteFile(ValuesFile, []byte(modified))
		},
	)
}

func (s *MissingConfigMap) Explanation() string {
	return "The appConfig.enabled flag in values.yaml was set to false, which prevented the " +
		"ConfigMap from being created. However, the Deployment template still had an envFrom " +
		"reference to the ConfigMap (controlled by the same flag in the template). When the " +
		"ConfigMap was missing, pods could not start. The fix is to set appConfig.enabled back " +
		"to true in values.yaml, or to remove the envFrom reference in the Deployment template."
}

func (s *MissingConfigMap) DiagnoseCommands() []string {
	return []string{
		"kubectl get pods -n applications",
		"kubectl describe pod -n applications -l app=django",
		"kubectl get configmap -n applications",
		"kubectl get events -n applications --sort-by=.lastTimestamp",
	}
}
