package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// OrphanedResource renames the Deployment in the template from "django" to
// "django-web" and breaks the Service selector. This leaves the old Deployment
// orphaned while the ingress-facing Service has no endpoints.
type OrphanedResource struct{}

func (s *OrphanedResource) Name() string {
	return "orphaned-resource"
}

func (s *OrphanedResource) Description() string {
	return "Renames the Deployment from 'django' to 'django-web' and changes the Service " +
		"selector so the ingress-facing Service has no endpoints."
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

			svcData, err := w.ReadFile(ServiceFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ServiceFile, err)
			}

			svcContent := string(svcData)
			selectorBlock := "  selector:\n    {{- include \"django-app.selectorLabels\" . | nindent 4 }}"
			brokenSelectorBlock := "  selector:\n    app: django-web\n    app.kubernetes.io/instance: {{ .Release.Name }}\n    app.kubernetes.io/name: {{ include \"django-app.name\" . }}"
			svcModified := strings.Replace(svcContent,
				selectorBlock,
				brokenSelectorBlock,
				1,
			)
			if svcModified == svcContent {
				return fmt.Errorf("could not find service selector to break in service.yaml")
			}

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

			svcData, err := w.ReadFile(ServiceFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", ServiceFile, err)
			}
			svcContent := string(svcData)
			selectorBlock := "  selector:\n    {{- include \"django-app.selectorLabels\" . | nindent 4 }}"
			brokenSelectorBlock := "  selector:\n    app: django-web\n    app.kubernetes.io/instance: {{ .Release.Name }}\n    app.kubernetes.io/name: {{ include \"django-app.name\" . }}"
			svcModified := strings.Replace(svcContent,
				brokenSelectorBlock,
				selectorBlock,
				1,
			)
			return w.WriteFile(ServiceFile, []byte(svcModified))
		},
	)
}

func (s *OrphanedResource) Explanation() string {
	return "The Deployment was renamed from 'django' to 'django-web' in the Helm template, " +
		"and the Service selector was changed to app=django-web. The rendered pods still carry " +
		"app=django, so the ingress-facing Service has no endpoints. Because prune is disabled, " +
		"the old 'django' Deployment also remains as an orphaned resource. The fix is to restore " +
		"the original Deployment name and Service selector in git, then prune or delete any old " +
		"orphaned resources once the desired state is correct."
}

func (s *OrphanedResource) DiagnoseCommands() []string {
	return []string{
		"kubectl get deployments -n applications",
		"kubectl get svc,endpoints -n applications django",
		"kubectl get pods -n applications --show-labels",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.resources}' | python3 -m json.tool",
		"kubectl describe deployment django -n applications",
		"kubectl describe deployment django-web -n applications",
	}
}
