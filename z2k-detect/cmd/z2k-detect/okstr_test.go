package main

import "testing"

func TestOkStr(t *testing.T) {
	yes, no := true, false
	for _, tc := range []struct {
		in   *bool
		want string
	}{
		{nil, "skip"},
		{&yes, "ok"},
		{&no, "fail"},
	} {
		if got := okStr(tc.in); got != tc.want {
			t.Errorf("okStr(%v) = %q, ожидалось %q", tc.in, got, tc.want)
		}
	}
}
