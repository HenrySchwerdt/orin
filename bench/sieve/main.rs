fn main() {
    let n = 10000000usize;
    let mut flags: Vec<i64> = Vec::new();
    for _ in 0..=n {
        flags.push(1);
    }
    flags[0] = 0;
    flags[1] = 0;
    let mut i = 2;
    while i * i <= n {
        if flags[i] == 1 {
            let mut j = i * i;
            while j <= n {
                flags[j] = 0;
                j += i;
            }
        }
        i += 1;
    }
    let count: i64 = flags.iter().sum();
    println!("primes<=10000000: {}", count);
}
