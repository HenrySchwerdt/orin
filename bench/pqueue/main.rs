use std::cmp::Reverse;
use std::collections::BinaryHeap;

fn next_rand(s: i64) -> i64 {
    (s * 1103515245 + 12345) % 2147483648
}

fn main() {
    let mut q: BinaryHeap<Reverse<(i64, i64)>> = BinaryHeap::new();
    let mut seed = 1i64;
    for i in 0..200000i64 {
        seed = next_rand(seed);
        q.push(Reverse((seed % 1000003, i)));
    }
    println!("size {}", q.len());
    let mut check = 0i64;
    for i in 0..400000i64 {
        seed = next_rand(seed);
        q.push(Reverse((seed % 1000003, i)));
        let Reverse((p, _)) = q.pop().unwrap();
        check = (check * 31 + p) % 1000000007;
    }
    println!("interleaved {} size {}", check, q.len());
    let (mut n, mut sum, mut last, mut ordered) = (0i64, 0i64, -1i64, true);
    while let Some(Reverse((p, _))) = q.pop() {
        if p < last {
            ordered = false;
        }
        last = p;
        n += 1;
        sum = (sum + p * (n % 1000)) % 1000000007;
    }
    println!("drained {} ordered {} sum {}", n, ordered, sum);
}
