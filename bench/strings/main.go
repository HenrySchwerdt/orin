package main

import (
	"fmt"
	"strconv"
	"strings"
)

func build(n int64) string {
	var b strings.Builder
	for i := int64(0); i < n; i++ {
		b.WriteString("item" + strconv.FormatInt(i, 10) + ",")
	}
	return b.String()
}

func main() {
	s := build(500000)
	parts := strings.Split(s, ",")
	joined := strings.Join(parts, ";")
	var sum, nonEmpty int64
	for _, p := range parts {
		if len(p) > 0 {
			v, _ := strconv.ParseInt(p[4:], 10, 64)
			sum += v
			nonEmpty++
		}
	}
	fmt.Printf("len %d\n", len(s))
	fmt.Printf("parts %d nonEmpty %d\n", len(parts), nonEmpty)
	fmt.Printf("joined %d\n", len(joined))
	fmt.Printf("sum %d\n", sum)
}
