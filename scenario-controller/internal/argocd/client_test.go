package argocd

import (
	"encoding/json"
	"testing"
)

func TestScenarioReadyAnnotations(t *testing.T) {
	annotations, err := scenarioReadyAnnotations("missing-configmap")
	if err != nil {
		t.Fatalf("scenarioReadyAnnotations() error = %v", err)
	}

	if got := annotations[FirstScenarioReadyAnnotation]; got != "true" {
		t.Fatalf("%s = %q, want true", FirstScenarioReadyAnnotation, got)
	}
	if got := annotations[CurrentScenarioAnnotation]; got != "missing-configmap" {
		t.Fatalf("%s = %q, want missing-configmap", CurrentScenarioAnnotation, got)
	}
}

func TestScenarioReadyAnnotationsRejectsEmptyScenarioName(t *testing.T) {
	if _, err := scenarioReadyAnnotations(""); err == nil {
		t.Fatal("scenarioReadyAnnotations() error = nil, want error")
	}
}

func TestAnnotationPatchEncodesMergePatch(t *testing.T) {
	patch, err := annotationPatch(map[string]string{
		FirstScenarioReadyAnnotation: "true",
		CurrentScenarioAnnotation:    "missing-configmap",
	})
	if err != nil {
		t.Fatalf("annotationPatch() error = %v", err)
	}

	var got struct {
		Metadata struct {
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal(patch, &got); err != nil {
		t.Fatalf("unmarshal patch: %v", err)
	}

	if got.Metadata.Annotations[FirstScenarioReadyAnnotation] != "true" {
		t.Fatalf("patch missing %s=true: %s", FirstScenarioReadyAnnotation, string(patch))
	}
	if got.Metadata.Annotations[CurrentScenarioAnnotation] != "missing-configmap" {
		t.Fatalf("patch missing %s=missing-configmap: %s", CurrentScenarioAnnotation, string(patch))
	}
}
