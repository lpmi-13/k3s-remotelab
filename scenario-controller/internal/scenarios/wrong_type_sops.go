package scenarios

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// WrongTypeSops re-encrypts the secrets file with an integer value where a
// string is expected (e.g., DB_PORT as the integer 5432 instead of the string
// "5432"). This causes Helm template rendering to fail because the deployment
// template uses {{ $value | quote }} which behaves differently for integers,
// or the application itself rejects the wrong type.
type WrongTypeSops struct{}

func (s *WrongTypeSops) Name() string {
	return "wrong-type-sops"
}

func (s *WrongTypeSops) Description() string {
	return "Re-encrypts the secrets file with an integer value where a string is expected " +
		"(DB_PORT: 5432 instead of DB_PORT: \"5432\"), causing type errors in Helm rendering " +
		"or application startup."
}

func (s *WrongTypeSops) Inject(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: update database secrets",
		func(w *git.WorkDir) error {
			ageKey := gitClient.SopsAgeKey()
			agePubKey := gitClient.AgePublicKey()

			if ageKey == "" || agePubKey == "" {
				return fmt.Errorf("SOPS_AGE_KEY or AGE_PUBLIC_KEY not configured")
			}

			// Create a plaintext secrets file with a wrong-type value.
			// DB_PORT as an integer instead of a string. The secrets override
			// values from values.yaml, so this will cause the Deployment env
			// to get an integer where the template expects a string.
			plaintext := `# Secrets for django-app
secrets:
  DB_PASSWORD: "remotelab"
  SECRET_KEY: "django-insecure-remotelab-key-change-in-production"
  DB_PORT: 5432
`
			plaintextPath := filepath.Join(w.Dir(), "plaintext-secrets.yaml")
			if err := os.WriteFile(plaintextPath, []byte(plaintext), 0o644); err != nil {
				return fmt.Errorf("failed to write plaintext secrets: %w", err)
			}
			defer os.Remove(plaintextPath)

			// Write the age key to a temp file for sops.
			keyFile, err := os.CreateTemp("", "age-key-*")
			if err != nil {
				return fmt.Errorf("failed to create temp key file: %w", err)
			}
			defer os.Remove(keyFile.Name())

			if _, err := keyFile.WriteString(ageKey); err != nil {
				keyFile.Close()
				return fmt.Errorf("failed to write age key: %w", err)
			}
			keyFile.Close()

			// Encrypt with sops.
			outputPath := w.FilePath(SecretsFile)
			cmd := exec.Command("sops",
				"--encrypt",
				"--age", agePubKey,
				"--input-type", "yaml",
				"--output-type", "yaml",
				"--output", outputPath,
				plaintextPath,
			)
			cmd.Env = append(os.Environ(),
				fmt.Sprintf("SOPS_AGE_KEY_FILE=%s", keyFile.Name()),
			)

			output, err := cmd.CombinedOutput()
			if err != nil {
				return fmt.Errorf("sops encrypt failed: %w\noutput: %s", err, string(output))
			}

			return nil
		},
	)
}

func (s *WrongTypeSops) Revert(gitClient *git.Client) error {
	return gitClient.CloneAndModify(
		"chore: fix database secrets types",
		func(w *git.WorkDir) error {
			ageKey := gitClient.SopsAgeKey()
			agePubKey := gitClient.AgePublicKey()

			if ageKey == "" || agePubKey == "" {
				return nil // cannot revert without keys
			}

			// Re-encrypt with correct types.
			plaintext := `# Secrets for django-app
secrets:
  DB_PASSWORD: "remotelab"
  SECRET_KEY: "django-insecure-remotelab-key-change-in-production"
  DB_PORT: "5432"
`
			plaintextPath := filepath.Join(w.Dir(), "plaintext-secrets.yaml")
			if err := os.WriteFile(plaintextPath, []byte(plaintext), 0o644); err != nil {
				return fmt.Errorf("failed to write plaintext: %w", err)
			}
			defer os.Remove(plaintextPath)

			keyFile, err := os.CreateTemp("", "age-key-*")
			if err != nil {
				return fmt.Errorf("failed to create temp key file: %w", err)
			}
			defer os.Remove(keyFile.Name())

			if _, err := keyFile.WriteString(ageKey); err != nil {
				keyFile.Close()
				return fmt.Errorf("failed to write age key: %w", err)
			}
			keyFile.Close()

			outputPath := w.FilePath(SecretsFile)
			cmd := exec.Command("sops",
				"--encrypt",
				"--age", agePubKey,
				"--input-type", "yaml",
				"--output-type", "yaml",
				"--output", outputPath,
				plaintextPath,
			)
			cmd.Env = append(os.Environ(),
				fmt.Sprintf("SOPS_AGE_KEY_FILE=%s", keyFile.Name()),
			)

			output, err := cmd.CombinedOutput()
			if err != nil {
				return fmt.Errorf("sops encrypt failed: %w\noutput: %s", err, string(output))
			}

			return nil
		},
	)
}

func (s *WrongTypeSops) Explanation() string {
	return "The secrets.yaml.enc file was re-encrypted with DB_PORT set to the integer 5432 " +
		"instead of the string \"5432\". When Helm renders the template, the {{ $value | quote }} " +
		"function wraps the integer differently, or the application receives an unexpected type. " +
		"The fix is to re-encrypt the secrets file with the correct string type: " +
		"DB_PORT: \"5432\" (quoted to ensure it remains a string)."
}

func (s *WrongTypeSops) DiagnoseCommands() []string {
	return []string{
		"kubectl get pods -n applications",
		"kubectl describe pod -n applications -l app=django",
		"kubectl logs -n applications -l app=django --tail=30",
		"kubectl get applications -n argocd django-app -o jsonpath='{.status.operationState.message}'",
	}
}
