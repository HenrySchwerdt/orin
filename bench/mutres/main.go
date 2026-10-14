// Same work as main.or: pointer-receiver methods on structs.
package main

import "fmt"

type reader struct {
	data []int64
	pos  int
}

func (r *reader) next() int64 {
	v := r.data[r.pos]
	r.pos++
	if r.pos == len(r.data) {
		r.pos = 0
	}
	return v
}

func (r *reader) skip() {
	r.pos++
	if r.pos == len(r.data) {
		r.pos = 0
	}
}

func (r *reader) cur() int64 { return r.data[r.pos] }

type q struct {
	r     reader
	total int64
}

func (x *q) stepRet() int64 {
	v := x.r.next()
	x.total += v
	return v
}

func (x *q) stepVoid() {
	x.total += x.r.cur()
	x.r.skip()
}

func main() {
	d := []int64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	qq := &q{r: reader{data: d}}
	r := &reader{data: d}
	var sum int64
	for i := 0; i < 10000000; i++ {
		sum += r.next()
	}
	fmt.Printf("ret %d %d\n", sum, r.pos)
	for i := 0; i < 10000000; i++ {
		r.skip()
		sum += r.cur()
	}
	fmt.Printf("void %d %d\n", sum, r.pos)
	for i := 0; i < 10000000; i++ {
		sum += qq.stepRet()
	}
	fmt.Printf("nested ret %d %d\n", sum, qq.total)
	for i := 0; i < 10000000; i++ {
		qq.stepVoid()
	}
	fmt.Printf("nested void %d %d\n", qq.total, qq.r.pos)
}
