struct Reader {
    data: Vec<i64>,
    pos: usize,
}
impl Reader {
    fn next(&mut self) -> i64 {
        let v = self.data[self.pos];
        self.pos += 1;
        if self.pos == self.data.len() {
            self.pos = 0;
        }
        v
    }
    fn skip(&mut self) {
        self.pos += 1;
        if self.pos == self.data.len() {
            self.pos = 0;
        }
    }
    fn cur(&self) -> i64 {
        self.data[self.pos]
    }
}
struct Q {
    r: Reader,
    total: i64,
}
impl Q {
    fn step_ret(&mut self) -> i64 {
        let v = self.r.next();
        self.total += v;
        v
    }
    fn step_void(&mut self) {
        self.total += self.r.cur();
        self.r.skip();
    }
}
fn main() {
    let d: Vec<i64> = (1..=16).collect();
    let mut q = Q { r: Reader { data: d.clone(), pos: 0 }, total: 0 };
    let mut r = Reader { data: d, pos: 0 };
    let mut sum = 0i64;
    for _ in 0..10000000 {
        sum += r.next();
    }
    println!("ret {} {}", sum, r.pos);
    for _ in 0..10000000 {
        r.skip();
        sum += r.cur();
    }
    println!("void {} {}", sum, r.pos);
    for _ in 0..10000000 {
        sum += q.step_ret();
    }
    println!("nested ret {} {}", sum, q.total);
    for _ in 0..10000000 {
        q.step_void();
    }
    println!("nested void {} {}", q.total, q.r.pos);
}
