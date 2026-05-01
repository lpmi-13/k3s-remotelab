package scenarios

import (
	"fmt"
	"strings"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// HMACMismatch modifies the encrypted data bytes in the SOPS file without
// updating the MAC (Message Authentication Code). This causes a MAC verification
// failure when helm-secrets tries to decrypt the file, since the MAC no longer
// matches the encrypted data.
type HMACMismatch struct{}

func (s *HMACMismatch) Name() string {
	return "hmac-mismatch"
}

func (s *HMACMismatch) Description() string {
	return "Modifies encrypted data values in the SOPS file without updating the MAC, " +
		"causing a MAC mismatch error during decryption."
}

func (s *HMACMismatch) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: update encrypted secrets configuration",
		func(w *git.WorkDir) error {
			data, err := w.ReadFile(SecretsFile)
			if err != nil {
				return fmt.Errorf("failed to read %s: %w", SecretsFile, err)
			}

			content := string(data)

			// Find the sops metadata block to ensure we only modify data above it.
			sopsIdx := strings.Index(content, "\nsops:\n")
			if sopsIdx == -1 {
				return fmt.Errorf("sops metadata block not found in %s", SecretsFile)
			}

			dataSection := content[:sopsIdx]
			sopsSection := content[sopsIdx:]

			// Find an encrypted value (ENC[AES256_GCM,...]) and tamper with it.
			// SOPS encrypted values look like: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
			encPrefix := "ENC[AES256_GCM,data:"
			encIdx := strings.Index(dataSection, encPrefix)
			if encIdx == -1 {
				return fmt.Errorf("no encrypted values found in %s", SecretsFile)
			}

			// Find the end of the data portion and modify a few characters.
			dataStart := encIdx + len(encPrefix)
			commaIdx := strings.Index(dataSection[dataStart:], ",")
			if commaIdx == -1 {
				return fmt.Errorf("malformed encrypted value in %s", SecretsFile)
			}

			// Tamper with the base64 data by replacing a few characters.
			encData := dataSection[dataStart : dataStart+commaIdx]
			if len(encData) < 4 {
				return fmt.Errorf("encrypted data too short to tamper with")
			}

			// Flip some characters in the base64-encoded ciphertext.
			tampered := []byte(encData)
			for i := 0; i < len(tampered) && i < 4; i++ {
				if tampered[i] >= 'a' && tampered[i] <= 'z' {
					tampered[i] = 'A' + (tampered[i] - 'a')
				} else if tampered[i] >= 'A' && tampered[i] <= 'Z' {
					tampered[i] = 'a' + (tampered[i] - 'A')
				} else if tampered[i] >= '0' && tampered[i] <= '9' {
					tampered[i] = '9' - (tampered[i] - '0')
				}
			}

			modified := dataSection[:dataStart] + string(tampered) + dataSection[dataStart+commaIdx:]
			return w.WriteFile(SecretsFile, []byte(modified+sopsSection))
		},
	)
}

func (s *HMACMismatch) Revert(gitClient *git.Client) error {
	// The user must re-encrypt the secrets file to fix the MAC.
	// After they fix it, revert is a no-op since the file should be valid.
	return gitClient.CloneAndModify(
		"chore: restore encrypted secrets integrity",
		func(w *git.WorkDir) error {
			return nil
		},
	)
}

func (s *HMACMismatch) Explanation() string {
	return "The encrypted data bytes in secrets.yaml.enc were modified without updating the " +
		"SOPS MAC (Message Authentication Code). SOPS uses an HMAC to verify that the encrypted " +
		"data has not been tampered with. When the MAC does not match the data, decryption fails " +
		"with a 'MAC mismatch' error. The fix is to re-encrypt the file with valid data using " +
		"sops, which will recalculate the MAC."
}

func (s *HMACMismatch) DiagnoseCommands() []string {
	return []string{
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'",
		"kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.operationState.message}'",
	}
}
