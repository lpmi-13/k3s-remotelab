package scenarios

import (
	"testing"

	"github.com/lpmi-13/k3s-remotelab/scenario-controller/internal/git"
)

type testScenario struct {
	name string
}

func (s testScenario) Name() string               { return s.name }
func (s testScenario) Description() string        { return "" }
func (s testScenario) Inject(_ *git.Client) error { return nil }
func (s testScenario) Revert(_ *git.Client) error { return nil }
func (s testScenario) Explanation() string        { return "" }
func (s testScenario) DiagnoseCommands() []string { return nil }

func TestRegistryReturnsEachScenarioBeforeRepeating(t *testing.T) {
	registry := NewRegistry()
	names := []string{"one", "two", "three", "four"}
	for _, name := range names {
		registry.Register(testScenario{name: name})
	}

	for cycle := 0; cycle < 5; cycle++ {
		seen := map[string]bool{}
		for i := 0; i < len(names); i++ {
			scenario := registry.Random()
			if seen[scenario.Name()] {
				t.Fatalf("cycle %d returned scenario %q more than once before all scenarios were used", cycle, scenario.Name())
			}
			seen[scenario.Name()] = true
		}
	}
}

func TestRegistryAvoidsImmediateRepeatAcrossShuffleBoundaries(t *testing.T) {
	registry := NewRegistry()
	for _, name := range []string{"one", "two", "three"} {
		registry.Register(testScenario{name: name})
	}

	var previous string
	for i := 0; i < 30; i++ {
		current := registry.Random().Name()
		if current == previous {
			t.Fatalf("scenario %q repeated immediately at draw %d", current, i)
		}
		previous = current
	}
}
