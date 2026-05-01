package scenarios

import (
	"log"
	"math/rand"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

// Scenario defines the interface that each failure scenario must implement.
type Scenario interface {
	// Name returns a short, unique identifier for the scenario.
	Name() string

	// Description returns a human-readable description of what the scenario does.
	Description() string

	// Inject performs the failure injection by modifying files in the git repository.
	Inject(gitClient *git.Client) error

	// Revert restores the original state after the user has fixed the issue.
	Revert(gitClient *git.Client) error

	// Explanation returns a detailed explanation of the scenario that is logged
	// after the user successfully fixes it.
	Explanation() string

	// DiagnoseCommands returns a list of kubectl commands that would help
	// diagnose the injected failure.
	DiagnoseCommands() []string
}

// Registry holds all registered scenarios and provides random selection.
type Registry struct {
	scenarios []Scenario
}

// NewRegistry creates a new empty scenario registry.
func NewRegistry() *Registry {
	return &Registry{}
}

// Register adds a scenario to the registry.
func (r *Registry) Register(s Scenario) {
	log.Printf("registered scenario: %s", s.Name())
	r.scenarios = append(r.scenarios, s)
}

// Random selects and returns a random scenario from the registry.
func (r *Registry) Random() Scenario {
	return r.scenarios[rand.Intn(len(r.scenarios))]
}

// Count returns the number of registered scenarios.
func (r *Registry) Count() int {
	return len(r.scenarios)
}

// Names returns the names of all registered scenarios.
func (r *Registry) Names() []string {
	names := make([]string, len(r.scenarios))
	for i, s := range r.scenarios {
		names[i] = s.Name()
	}
	return names
}

// Common file paths within the cloned repo that scenarios operate on.
const (
	ValuesFile     = "chart/django-app/values.yaml"
	SecretsFile    = "chart/django-app/secrets.yaml.enc"
	DeploymentFile = "chart/django-app/templates/deployment.yaml"
	ServiceFile    = "chart/django-app/templates/service.yaml"
	ConfigMapFile  = "chart/django-app/templates/configmap.yaml"
	MigrateJobFile = "chart/django-app/templates/migrate-job.yaml"
	HelpersFile    = "chart/django-app/templates/_helpers.tpl"
)
