package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// OrphanedResource renames the Deployment in the template from "django" to
// "django-web". This causes ArgoCD to create a new Deployment named "django-web"
// while the old "django" Deployment is still running. ArgoCD reports orphaned
// resources, and the old Deployment may conflict with the new one (same labels,
// same selector). The user must delete the orphaned "django" Deployment.
type OrphanedResource struct{}

func (s *OrphanedResource) Name() string {
	return "orphaned-resource"
}

func (s *OrphanedResource) Description() string {
	return "Renames the Deployment from 'django' to 'django-web' in the template, " +
		"orphaning the old Deployment and causing resource conflicts."
}

func (s *OrphanedResource) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"refactor: rename deployment for clarity",
		func(w *git.WorkDir) error {
			// Modify the deployment template to rename from django to django-web.
			data, err := w.ReadFile(DeploymentFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", DeploymentFile, err)
			}

			content := string(data)

			// Replace "name: django" with "name: django-web" (only the metadata.name).
			// We need to be precise to only change the Deployment name, not other references.
			modified := strings.Replace(content,
				"  name: django\n  namespace:",
				"  name: django-web\n  namespace:",
				1,
			)

			if modified == content {
				return fmt.Errorf("could not find deployment name to rename in deployment.yaml")
			}

			// Also update the Service to point to the new deployment name
			// by modifying the service template.
			svcData, err := w.ReadFile(ServiceFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ServiceFile, err)
			}

			svcContent := string(svcData)
			svcModified := strings.Replace(svcContent,
				"  name: django\n  namespace:",
				"  name: django-web\n  namespace:",
				1,
			)

			if err := w.WriteFile(DeploymentFile, []byte(modified)); err != nil {
				return err
			}
			return w.WriteFile(ServiceFile, []byte(svcModified))
		},
	)
}

func (s *OrphanedResource) Revert(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"revert: restore original deployment name",
		func(w *git.WorkDir) error {
			// Restore deployment name.
			data, err := w.ReadFile(DeploymentFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", DeploymentFile, err)
			}
			content := string(data)
			modified := strings.Replace(content,
				"  name: django-web\n  namespace:",
				"  name: django\n  namespace:",
				1,
			)
			if err := w.WriteFile(DeploymentFile, []byte(modified)); err != nil {
				return err
			}

			// Restore service name.
			svcData, err := w.ReadFile(ServiceFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ServiceFile, err)
			}
			svcContent := string(svcData)
			svcModified := strings.Replace(svcContent,
				"  name: django-web\n  namespace:",
				"  name: django\n  namespace:",
				1,
			)
			return w.WriteFile(ServiceFile, []byte(svcModified))
		},
	)
}

func (s *OrphanedResource) Explanation() string {
	return "The Deployment was renamed from 'django' to 'django-web' in the Helm template. " +
		"ArgoCD created the new 'django-web' Deployment but left the old 'django' Deployment " +
		"running (since prune is disabled). The old Deployment becomes an orphaned resource, " +
		"and because both Deployments use the same label selector, they compete for the same " +
		"pods, causing instability. The fix is to delete the orphaned 'django' Deployment " +
		"(kubectl delete deployment django -n applications) and either keep the new name or " +
		"revert the rename in git."
}

func (s *OrphanedResource) DiagnoseCommands() []string {
	return []string{
		"kubectl get deployments -n applications",
		"kubectl get pods -n applications -l app=django",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.resources}' | python3 -m json.tool",
		"kubectl describe deployment django -n applications",
		"kubectl describe deployment django-web -n applications",
	}
}
