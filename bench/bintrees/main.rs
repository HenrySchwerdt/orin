struct Node {
    l: Option<Box<Node>>,
    r: Option<Box<Node>>,
}
fn build(d: i64) -> Option<Box<Node>> {
    if d == 0 {
        return Some(Box::new(Node { l: None, r: None }));
    }
    Some(Box::new(Node { l: build(d - 1), r: build(d - 1) }))
}
fn check(t: &Option<Box<Node>>) -> i64 {
    match t {
        None => 0,
        Some(n) => 1 + check(&n.l) + check(&n.r),
    }
}
fn main() {
    let max_depth = 16;
    let long_lived = build(max_depth);
    let mut total = 0i64;
    let mut d = 4;
    while d <= max_depth {
        let iters = 1i64 << (22 - d);
        let mut sum = 0i64;
        for _ in 0..iters {
            sum += check(&build(d));
        }
        println!("depth {} trees {} check {}", d, iters, sum);
        total += sum;
        d += 4;
    }
    println!("long lived check {}", check(&long_lived));
    println!("total {}", total);
}
