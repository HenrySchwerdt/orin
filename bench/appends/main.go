// Same work as main.or. Go's `s += t` is quadratic, so strings are built with strings.Builder and arrays with append
// (the amortised equivalents of what Orin's `x = x + e` compiles to).
package main

import (
	"fmt"
	"strings"
)

type rec struct {
	s strings.Builder
	a []int64
}

type buf struct{ s strings.Builder }

func (b *buf) add(t string) { b.s.WriteString(t) }

func main() {
	var s strings.Builder
	for i := 0; i < 200000; i++ {
		s.WriteString("x")
	}
	fmt.Printf("local %d\n", s.Len())
	var r rec
	for i := 0; i < 200000; i++ {
		r.s.WriteString("y")
	}
	fmt.Printf("field %d\n", r.s.Len())
	var b buf
	for i := 0; i < 200000; i++ {
		b.add("z")
	}
	fmt.Printf("class field %d\n", b.s.Len())
	rs := make([]rec, 2)
	for i := 0; i < 200000; i++ {
		rs[1].s.WriteString("w")
	}
	fmt.Printf("element %d %d\n", rs[1].s.Len(), rs[0].s.Len())
	var a []int64
	for i := int64(0); i < 100000; i++ {
		a = append(a, i)
	}
	fmt.Printf("array %d %d\n", len(a), a[99999])
	for i := int64(0); i < 100000; i++ {
		r.a = append(r.a, i, i)
	}
	fmt.Printf("array field %d %d\n", len(r.a), r.a[199999])
}
