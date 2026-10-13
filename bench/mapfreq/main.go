package main

import (
	"fmt"
	"strconv"
)

func main() {
	freq := map[string]int64{}
	for i := 0; i < 1000000; i++ {
		key := "w" + strconv.Itoa((i*7919)%50000)
		freq[key] = freq[key] + 1
	}
	var check int64
	for k, v := range freq {
		check += v * int64(len(k))
	}
	fmt.Printf("distinct: %d\n", len(freq))
	fmt.Printf("check: %d\n", check)
	fmt.Printf("w123: %d\n", freq["w123"])
}
