// Ordering rules for the Room groups table (ADR 0002, phase 3d follow-up).
//
// The kernel renumbers display_order in Room, so a reorder that disagrees with
// GroupRepo.setDisplayOrder breaks the tab order: the DAO sorts by display_order,
// so a 1-based run leaves a hole and an omitted group keeps its old number in the
// middle of the new sequence.
package mobile

import (
	"reflect"
	"testing"
)

// groupRow rather than `group`: autoselector.go and command.go import
// sing-box's protocol/group, and a package-level func of that name shadows the
// import for the whole test build.
func groupRow(id int64, order int64) roomGroup {
	return roomGroup{id: id, order: order}
}

func TestOrderedGroupIDsIsZeroBased(t *testing.T) {
	groups := []roomGroup{groupRow(1, 0), groupRow(2, 1)}
	got := orderedGroupIDs(groups, []int64{2, 1})
	if !reflect.DeepEqual(got, []int64{2, 1}) {
		t.Fatalf("want [2 1], got %v", got)
	}
}

func TestOrderedGroupIDsAppendsOmittedGroups(t *testing.T) {
	groups := []roomGroup{groupRow(1, 0), groupRow(2, 1), groupRow(3, 2)}
	got := orderedGroupIDs(groups, []int64{3})
	if !reflect.DeepEqual(got, []int64{3, 1, 2}) {
		t.Fatalf("want [3 1 2], got %v", got)
	}
}

func TestOrderedGroupIDsDropsUnknownAndDuplicateIDs(t *testing.T) {
	groups := []roomGroup{groupRow(1, 0), groupRow(2, 1)}
	got := orderedGroupIDs(groups, []int64{99, 2, 2, 1})
	if !reflect.DeepEqual(got, []int64{2, 1}) {
		t.Fatalf("duplicates and unknown ids must not shift the order: %v", got)
	}
}

func TestOrderedGroupIDsLeavesNoHoles(t *testing.T) {
	groups := []roomGroup{groupRow(1, 5), groupRow(2, 9), groupRow(3, 42)}
	got := orderedGroupIDs(groups, []int64{1, 2, 3})
	if !reflect.DeepEqual(got, []int64{1, 2, 3}) {
		t.Fatalf("want [1 2 3], got %v", got)
	}
}

func TestOrderedGroupIDsWithEmptyInputKeepsStoredOrder(t *testing.T) {
	groups := []roomGroup{groupRow(7, 0), groupRow(4, 1)}
	got := orderedGroupIDs(groups, nil)
	if !reflect.DeepEqual(got, []int64{7, 4}) {
		t.Fatalf("an empty request must keep the stored order: %v", got)
	}
}
