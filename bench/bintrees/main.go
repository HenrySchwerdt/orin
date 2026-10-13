package main

import "fmt"

// A nil child plays the role of Orin's `Leaf` variant.
type Node struct{ l, r *Node }

func build(d int64) *Node {
	if d == 0 {
		return &Node{nil, nil}
	}
	return &Node{build(d - 1), build(d - 1)}
}

func check(t *Node) int64 {
	if t == nil {
		return 0
	}
	return 1 + check(t.l) + check(t.r)
}

func main() {
	const maxDepth = 16
	longLived := build(maxDepth)
	var total int64
	for d := int64(4); d <= maxDepth; d += 4 {
		iters := int64(1)
		for k := int64(0); k < 22-d; k++ {
			iters *= 2
		}
		var sum int64
		for i := int64(0); i < iters; i++ {
			sum += check(build(d))
		}
		fmt.Printf("depth %d trees %d check %d\n", d, iters, sum)
		total += sum
	}
	fmt.Printf("long lived check %d\n", check(longLived))
	fmt.Printf("total %d\n", total)
}
