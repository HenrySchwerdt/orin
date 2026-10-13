package main

import "fmt"

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func qs(xs []int64) []int64 {
	if len(xs) <= 1 {
		return xs
	}
	p := xs[0]
	lo := []int64{}
	eq := []int64{}
	hi := []int64{}
	for _, x := range xs {
		if x < p {
			lo = append(lo, x)
		} else if x == p {
			eq = append(eq, x)
		} else {
			hi = append(hi, x)
		}
	}
	// concat allocates a fresh array, as in Orin
	l := qs(lo)
	h := qs(hi)
	r := make([]int64, 0, len(l)+len(eq)+len(h))
	r = append(r, l...)
	r = append(r, eq...)
	r = append(r, h...)
	return r
}

func main() {
	a := []int64{}
	x := int64(42)
	for i := 0; i < 1000000; i++ {
		x = lcg(x)
		a = append(a, (x/16)%1000000)
	}
	s := qs(a)
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
