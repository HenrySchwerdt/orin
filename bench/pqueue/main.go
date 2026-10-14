// Same algorithm as main.or with container/heap (binary heap of (priority, value) pairs). Ties between equal
// priorities are not FIFO here; the checksums only depend on the popped priorities.
package main

import (
	"container/heap"
	"fmt"
)

type item struct {
	prio int64
	val  int64
}

type pq []item

func (h pq) Len() int            { return len(h) }
func (h pq) Less(i, j int) bool  { return h[i].prio < h[j].prio }
func (h pq) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *pq) Push(x interface{}) { *h = append(*h, x.(item)) }
func (h *pq) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

func nextRand(s int64) int64 { return (s*1103515245 + 12345) % 2147483648 }

func main() {
	q := &pq{}
	seed := int64(1)
	for i := int64(0); i < 200000; i++ {
		seed = nextRand(seed)
		heap.Push(q, item{seed % 1000003, i})
	}
	fmt.Printf("size %d\n", q.Len())
	check := int64(0)
	for i := int64(0); i < 400000; i++ {
		seed = nextRand(seed)
		heap.Push(q, item{seed % 1000003, i})
		e := heap.Pop(q).(item)
		check = (check*31 + e.prio) % 1000000007
	}
	fmt.Printf("interleaved %d size %d\n", check, q.Len())
	n := int64(0)
	sum := int64(0)
	last := int64(-1)
	ordered := true
	for q.Len() > 0 {
		e := heap.Pop(q).(item)
		if e.prio < last {
			ordered = false
		}
		last = e.prio
		n++
		sum = (sum + e.prio*(n%1000)) % 1000000007
	}
	fmt.Printf("drained %d ordered %t sum %d\n", n, ordered, sum)
}
