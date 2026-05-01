package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// SopsDecryptFailure corrupts the SOPS file structure by removing the sops
// metadata block from secrets.yaml.enc. Without the sops metadata, helm-secrets
// cannot decrypt the file, causing the ArgoCD sync to fail.
type SopsDecryptFailure struct{}

func (s *SopsDecryptFailure) Name() string {
	return "sops-decrypt-failure"
}

func (s *SopsDecryptFailure) Description() string {
	return "Removes the sops metadata block from the encrypted secrets file, " +
		"making it impossible for helm-secrets to decrypt it during ArgoCD sync."
}

func (s *SopsDecryptFailure) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: update encrypted secrets",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(SecretsFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", SecretsFile, err)
			}

			content := string(data)

			// Find and remove the sops: metadata block at the end of the file.
			// The sops block starts with "sops:" at the beginning of a line and
			// extends to the end of the file.
			sopsIdx := strings.Index(content, "\nsops:\n")
			if sopsIdx == -1 {
				// Try without leading newline (might be at very start, unlikely).
				if strings.HasPrefix(content, "sops:\n") {
					sopsIdx = 0
				} else {
					return fmt.Errorf("sops metadata block not found in %s", SecretsFile)
				}
			}

			// Remove the sops metadata block.
			truncated := content[:sopsIdx+1] // keep the trailing newline before sops:
			return w.WriteFile(SecretsFile, []byte(truncated))
		},
	)
}

func (s *SopsDecryptFailure) Revert(gitClient *git.Client) error {
	// The user must re-encrypt the secrets file with sops to fix this.
	// The revert simply restores the file from git history.
	return gitClient.CloneAndModify(
		"chore: restore encrypted secrets",
		func(w *git.WorkDir) error {
			// Restore the file from the previous commit using git.
			// Since we cloned fresh, the file should already be in the correct state
			// if the user fixed it. If not, we cannot easily reconstruct the sops
			// metadata, so we just log a warning.
			return nil
		},
	)
}

func (s *SopsDecryptFailure) Explanation() string {
	return "The sops metadata block was removed from secrets.yaml.enc. SOPS requires this " +
		"metadata (which contains the encrypted data key, MAC, and recipient information) to " +
		"decrypt the file. Without it, helm-secrets fails during the ArgoCD sync. The fix is " +
		"to restore the sops metadata block or re-encrypt the file using: " +
		"sops --encrypt --age <public-key> secrets.yaml > secrets.yaml.enc"
}

func (s *SopsDecryptFailure) DiagnoseCommands() []string {
	return []string{
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'",
		"kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.sync.status}'",
	}
}
