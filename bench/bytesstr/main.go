// Same work as main.or with []byte(s) and string(b).
package main

import (
	"fmt"
	"strings"
)

func main() {
	s := strings.Repeat("0123456789abcdef", 65536)
	total := 0
	for round := 0; round < 40; round++ {
		b := []byte(s)
		t := string(b)
		total += len(t) + int(t[round*7919]) + int(b[round])
	}
	fmt.Printf("len %d\n", len(s))
	fmt.Printf("total %d\n", total)
}
