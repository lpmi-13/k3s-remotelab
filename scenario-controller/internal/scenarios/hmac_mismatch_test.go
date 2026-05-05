package scenarios

import (
	"strings"
	"testing"
)

func TestTamperSopsCiphertextSkipsEncryptedComments(t *testing.T) {
	input := `#ENC[AES256_GCM,data:COMMENT,iv:iv,tag:tag,type:comment]
secrets:
    DB_PASSWORD: ENC[AES256_GCM,data:abcd1234,iv:iv,tag:tag,type:str]
sops:
    mac: ENC[AES256_GCM,data:mac,iv:iv,tag:tag,type:str]
`

	output, err := tamperSopsCiphertext(input)
	if err != nil {
		t.Fatalf("tamperSopsCiphertext returned error: %v", err)
	}

	if !strings.Contains(output, "data:COMMENT") {
		t.Fatal("encrypted comment was modified")
	}
	if strings.Contains(output, "data:abcd1234") {
		t.Fatal("secret ciphertext was not modified")
	}
}
