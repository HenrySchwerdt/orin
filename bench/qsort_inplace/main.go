package main

import "fmt"

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func sortInts(xs []int64) []int64 {
	a := make([]int64, len(xs)) // Orin copies on first write to a shared array
	copy(a, xs)
	stack := []uint64{0, uint64(len(a) - 1)}
	for len(stack) > 0 {
		hi := stack[len(stack)-1]
		lo := stack[len(stack)-2]
		stack = stack[:len(stack)-2]
		p := a[hi]
		i, j := lo, lo
		for j < hi {
			if a[j] < p {
				a[i], a[j] = a[j], a[i]
				i++
			}
			j++
		}
		a[i], a[hi] = a[hi], a[i]
		if i > lo+1 {
			stack = append(stack, lo, i-1)
		}
		if hi > i+1 {
			stack = append(stack, i+1, hi)
		}
	}
	return a
}

func main() {
	a := []int64{}
	x := int64(42)
	for i := 0; i < 1000000; i++ {
		x = lcg(x)
		a = append(a, (x/16)%1000000)
	}
	s := sortInts(a)
	var cs int64
	sorted := 1
	for k := 0; k < len(s); k++ {
		cs = (cs*31 + s[k]) % 1000000007
		if k > 0 && s[k-1] > s[k] {
			sorted = 0
		}
	}
	fmt.Printf("sorted %d\n", sorted)
	fmt.Printf("checksum %d\n", cs)
}
