package main

import (
	"fmt"
	"strconv"
)

type Entry struct {
	word  string
	count int64
}

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func hash(w string) int {
	h := 0
	for i := 0; i < len(w); i++ {
		h = (h*31 + int(w[i])) % 1024
	}
	return h
}

func findIdx(buckets [][]Entry, h int, w string) int {
	b := buckets[h]
	for j := 0; j < len(b); j++ {
		if b[j].word == w {
			return j
		}
	}
	return -1
}

func main() {
	buckets := make([][]Entry, 0)
	for i := 0; i < 1024; i++ {
		buckets = append(buckets, []Entry{})
	}
	x := int64(42)
	for n := 0; n < 1000000; n++ {
		x = lcg(x)
		w := "w" + strconv.FormatInt((x/65536)%5000, 10)
		h := hash(w)
		idx := findIdx(buckets, h, w)
		if idx >= 0 {
			buckets[h][idx].count++
		} else {
			buckets[h] = append(buckets[h], Entry{w, 1})
		}
	}
	var distinct, weighted, maxCount int64
	for _, b := range buckets {
		for _, e := range b {
			distinct++
			weighted += e.count * int64(len(e.word))
			if e.count > maxCount {
				maxCount = e.count
			}
		}
	}
	fmt.Printf("distinct %d\n", distinct)
	fmt.Printf("weighted %d\n", weighted)
	fmt.Printf("max %d\n", maxCount)
}
