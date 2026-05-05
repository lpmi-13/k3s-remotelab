package argocd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// applicationGVR is the GroupVersionResource for ArgoCD Application CRs.
var applicationGVR = schema.GroupVersionResource{
	Group:    "argoproj.io",
	Version:  "v1alpha1",
	Resource: "applications",
}

// Client checks the health of an ArgoCD Application by reading its
// status from the Kubernetes API. This is simpler and more reliable than
// using the ArgoCD REST API (no auth token needed, just RBAC).
type Client struct {
	dynClient dynamic.Interface
	appName   string
	namespace string // ArgoCD applications live in the "argocd" namespace
}

// NewClient creates a new ArgoCD client that reads Application CRs from the
// Kubernetes API using in-cluster configuration.
func NewClient(argocdServer, appName string) (*Client, error) {
	_ = argocdServer // kept for config parity; we use the K8s API directly

	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to get in-cluster config: %w", err)
	}

	dynClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	log.Printf("argocd client initialised: watching application %q in namespace %q via K8s API", appName, "argocd")

	return &Client{
		dynClient: dynClient,
		appName:   appName,
		namespace: "argocd",
	}, nil
}

// GetAppStatus returns the health, sync, and operation phase of the ArgoCD
// Application. It reads .status.health.status, .status.sync.status, and the
// active operation state from the Application CR.
//
// Typical health values: "Healthy", "Degraded", "Progressing", "Missing", "Unknown"
// Typical sync values:   "Synced", "OutOfSync", "Unknown"
// Typical operation phases: "Running", "Succeeded", "Failed", "Error", "Unknown"
func (c *Client) GetAppStatus(ctx context.Context) (health string, sync string, operationPhase string, err error) {
	app, err := c.dynClient.Resource(applicationGVR).Namespace(c.namespace).Get(ctx, c.appName, metav1.GetOptions{})
	if err != nil {
		return "", "", "", fmt.Errorf("failed to get application %q: %w", c.appName, err)
	}

	health, err = extractNestedString(app, "status", "health", "status")
	if err != nil {
		return "", "", "", fmt.Errorf("failed to read health status: %w", err)
	}

	sync, err = extractNestedString(app, "status", "sync", "status")
	if err != nil {
		return "", "", "", fmt.Errorf("failed to read sync status: %w", err)
	}

	// ArgoCD can leave .status.operationState.phase as "Running" after a user
	// terminates a failed sync retry. The top-level .operation field is the
	// active operation; if it is absent, the app should not be considered busy.
	if _, found, err := unstructured.NestedMap(app.Object, "operation"); err != nil {
		return "", "", "", fmt.Errorf("failed to read active operation: %w", err)
	} else if !found {
		return health, sync, "Succeeded", nil
	}

	operationPhase, err = extractNestedString(app, "status", "operationState", "phase")
	if err != nil {
		return "", "", "", fmt.Errorf("failed to read operation phase: %w", err)
	}

	return health, sync, operationPhase, nil
}

// RequestHardRefresh asks ArgoCD to immediately refresh the Application and
// invalidate cached manifest generation results.
func (c *Client) RequestHardRefresh(ctx context.Context) error {
	patch := []byte(`{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}`)
	_, err := c.dynClient.Resource(applicationGVR).Namespace(c.namespace).Patch(
		ctx,
		c.appName,
		types.MergePatchType,
		patch,
		metav1.PatchOptions{},
	)
	if err != nil {
		return fmt.Errorf("failed to request hard refresh for application %q: %w", c.appName, err)
	}
	return nil
}

// extractNestedString safely reads a nested string field from an unstructured
// object. Returns "Unknown" if the field path does not exist.
func extractNestedString(obj *unstructured.Unstructured, fields ...string) (string, error) {
	val, found, err := unstructured.NestedString(obj.Object, fields...)
	if err != nil {
		return "", err
	}
	if !found {
		return "Unknown", nil
	}
	return val, nil
}

// GetAppRaw returns the full Application CR as raw JSON (useful for debugging).
func (c *Client) GetAppRaw(ctx context.Context) ([]byte, error) {
	app, err := c.dynClient.Resource(applicationGVR).Namespace(c.namespace).Get(ctx, c.appName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to get application %q: %w", c.appName, err)
	}
	return json.MarshalIndent(app.Object, "", "  ")
}
