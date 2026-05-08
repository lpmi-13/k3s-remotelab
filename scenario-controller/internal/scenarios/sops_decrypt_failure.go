package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/argo-remotelab/scenario-controller/internal/git"
)

// SopsDecryptFailure corrupts the age-encrypted SOPS data key. SOPS can still
// identify the file as encrypted, but it cannot recover the data key, causing
// ArgoCD manifest generation to fail.
type SopsDecryptFailure struct{}

func (s *SopsDecryptFailure) Name() string {
	return "sops-decrypt-failure"
}

func (s *SopsDecryptFailure) Description() string {
	return "Corrupts the age-encrypted SOPS data key, making it impossible for " +
		"helm-secrets to decrypt the file during ArgoCD sync."
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

			marker := "-----BEGIN AGE ENCRYPTED FILE-----\n"
			markerIdx := strings.Index(content, marker)
			if markerIdx == -1 {
				return fmt.Errorf("age encrypted data key block not found in %s", SecretsFile)
			}

			dataStart := markerIdx + len(marker)
			for dataStart < len(content) && (content[dataStart] == ' ' || content[dataStart] == '\t') {
				dataStart++
			}
			if dataStart >= len(content) || content[dataStart] == '\n' {
				return fmt.Errorf("age encrypted data key block is malformed in %s", SecretsFile)
			}

			replacement := byte('X')
			if content[dataStart] == replacement {
				replacement = 'Y'
			}

			modified := content[:dataStart] + string(replacement) + content[dataStart+1:]
			return w.WriteFile(SecretsFile, []byte(modified))
		},
	)
}

func (s *SopsDecryptFailure) Revert(gitClient *git.Client) error {
	// The user must restore or re-encrypt the SOPS file to fix this. Once the
	// application is healthy again, there is nothing else for the controller to
	// undo.
	return gitClient.CloneAndModify(
		"chore: restore encrypted secrets",
		func(w *git.WorkDir) error {
			return nil
		},
	)
}

func (s *SopsDecryptFailure) Explanation() string {
	return "The age-encrypted SOPS data key in secrets.yaml.enc was corrupted. SOPS can " +
		"still identify the file as encrypted, but it cannot decrypt the data key needed " +
		"to read the secret values, so helm-secrets fails during ArgoCD manifest " +
		"generation. The fix is to restore the encrypted file from git history or " +
		"re-encrypt it with: sops --encrypt --age <public-key> secrets.yaml > secrets.yaml.enc"
}

func (s *SopsDecryptFailure) DiagnoseCommands() []string {
	return []string{
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'",
		"kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.sync.status}'",
	}
}
