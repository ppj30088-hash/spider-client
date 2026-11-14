// Reading a Room cell must not have to know it arrived as text (ADR 0002, phase 3d).
//
// sqlite3_get_table hands every cell back as a Go `string`, whatever the
// declared column type (room_db.go queryRows). The row helpers grew up on JSON
// documents, where a number is a float64, so their switches had no `string`
// arm: `rowInt64` answered 0 for every Room row, and `findProfileByID` compared
// 0 == 70 for all of them. The visible symptom was `profileNodeConfig` and
// friends answering "no proxy with id 70" for a row that was right there —
// deterministically, for every node, because no id ever matched.
//
// These tests pin the decode itself, and the two row filters it feeds.
package mobile

import (
	"reflect"
	"testing"
)

func TestRowInt64ReadsTextCells(t *testing.T) {
	if got := rowInt64(row{"id": "70"}, "id"); got != 70 {
		t.Fatalf("a text cell must decode to its number, got %d", got)
	}
	if got := rowInt64(row{"id": "-7"}, "id"); got != -7 {
		t.Fatalf("a negative text cell must keep its sign, got %d", got)
	}
	// Larger than a 32-bit int: the decode must not narrow.
	const large = int64(1) << 40
	if got := rowInt64(row{"id": "1099511627776"}, "id"); got != large {
		t.Fatalf("a wide text cell must survive intact, got %d", got)
	}
}

func TestRowInt64LeavesNonNumbersAtZero(t *testing.T) {
	if got := rowInt64(row{"id": "nope"}, "id"); got != 0 {
		t.Fatalf("an unparseable cell reads as 0, got %d", got)
	}
	if got := rowInt64(row{"id": ""}, "id"); got != 0 {
		t.Fatalf("an empty cell reads as 0, got %d", got)
	}
	if got := rowInt64(row{"id": nil}, "id"); got != 0 {
		t.Fatalf("a NULL cell reads as 0, got %d", got)
	}
}

func TestRowIntDecodesLikeRowInt64(t *testing.T) {
	if got := rowInt(row{"type": "3"}, "type"); got != 3 {
		t.Fatalf("rowInt must agree with rowInt64 on text cells, got %d", got)
	}
}

// The document store still decodes JSON numbers, so the new arm must not have
// cost the old ones anything.
func TestRowInt64KeepsJSONNumbers(t *testing.T) {
	if got := rowInt64(row{"id": float64(70)}, "id"); got != 70 {
		t.Fatalf("a JSON float64 must still decode, got %d", got)
	}
	if got := rowInt64(row{"id": int64(70)}, "id"); got != 70 {
		t.Fatalf("a re-encoded int64 must still decode, got %d", got)
	}
	if got := rowInt64(row{"id": 70}, "id"); got != 70 {
		t.Fatalf("an int must still decode, got %d", got)
	}
}

func TestFindProfileByIDMatchesTextCells(t *testing.T) {
	rows := []row{
		{"id": "70", "gid": "3", "user_order": "0", "type": "ss", "outbound_json": "{}"},
	}
	if got := findProfileByID(rows, 70); got == nil {
		t.Fatal("a text id must match the numeric id the action carries")
	}
	if got := findProfileByID(rows, 0); got != nil {
		t.Fatalf("id 0 names no row, got %v", got)
	}
	if got := findProfileByID(rows, 71); got != nil {
		t.Fatalf("a neighbour id must not match, got %v", got)
	}
}

func TestProfilesOfGroupMatchesTextCells(t *testing.T) {
	rows := []row{
		{"id": "70", "gid": "3", "user_order": "1"},
		{"id": "71", "gid": "3", "user_order": "0"},
		{"id": "72", "gid": "4", "user_order": "0"},
	}
	got := profilesOfGroup(rows, 3)
	ids := make([]int64, 0, len(got))
	for _, r := range got {
		ids = append(ids, rowInt64(r, "id"))
	}
	// Filtered by gid and then sorted by user_order, the DAO's order.
	if !reflect.DeepEqual(ids, []int64{71, 70}) {
		t.Fatalf("want [71 70], got %v", ids)
	}
}
