package main

import "fmt"

func sieve(n int) int64 {
	flags := []int64{}
	for i := 0; i <= n; i++ {
		flags = append(flags, 1)
	}
	flags[0] = 0
	flags[1] = 0
	for i := 2; i*i <= n; i++ {
		if flags[i] == 1 {
			for j := i * i; j <= n; j += i {
				flags[j] = 0
			}
		}
	}
	var count int64
	for i := 0; i <= n; i++ {
		count += flags[i]
	}
	return count
}

func main() { fmt.Printf("primes<=10000000: %d\n", sieve(10000000)) }
