package scenarios

import (
	"strings"
	"testing"
)

func TestTamperSopsGlobalMACOnlyChangesMAC(t *testing.T) {
	input := `secrets:
    DB_PASSWORD: ENC[AES256_GCM,data:abcd1234,iv:iv,tag:tag,type:str]
    mac: ENC[AES256_GCM,data:valuemac1234,iv:iv,tag:tag,type:str]
sops:
    age:
        - recipient: age123
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            payload
            -----END AGE ENCRYPTED FILE-----
    mac: ENC[AES256_GCM,data:macdata1234,iv:iv,tag:tag,type:str]
`

	output, err := tamperSopsGlobalMAC(input)
	if err != nil {
		t.Fatalf("tamperSopsGlobalMAC returned error: %v", err)
	}

	if !strings.Contains(output, "data:abcd1234") {
		t.Fatal("secret ciphertext was modified")
	}
	if !strings.Contains(output, "data:valuemac1234") {
		t.Fatal("non-sops mac value was modified")
	}
	if strings.Contains(output, "data:macdata1234") {
		t.Fatal("sops mac metadata was not modified")
	}
	if !strings.Contains(output, "recipient: age123") {
		t.Fatal("sops age metadata was modified")
	}
}

func TestTamperSopsGlobalMACRequiresMAC(t *testing.T) {
	if _, err := tamperSopsGlobalMAC("secrets: {}\n"); err == nil {
		t.Fatal("expected error for missing sops mac metadata")
	}
}
