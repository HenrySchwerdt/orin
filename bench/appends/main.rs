#[derive(Default)]
struct Rec {
    s: String,
    a: Vec<i64>,
}
#[derive(Default)]
struct Buf {
    s: String,
}
impl Buf {
    fn add(&mut self, t: &str) {
        self.s.push_str(t);
    }
}
fn main() {
    let mut s = String::new();
    for _ in 0..200000 {
        s.push('x');
    }
    println!("local {}", s.len());
    let mut r = Rec::default();
    for _ in 0..200000 {
        r.s.push('y');
    }
    println!("field {}", r.s.len());
    let mut b = Buf::default();
    for _ in 0..200000 {
        b.add("z");
    }
    println!("class field {}", b.s.len());
    let mut rs = vec![Rec::default(), Rec::default()];
    for _ in 0..200000 {
        rs[1].s.push('w');
    }
    println!("element {} {}", rs[1].s.len(), rs[0].s.len());
    let mut a: Vec<i64> = Vec::new();
    for i in 0..100000i64 {
        a.push(i);
    }
    println!("array {} {}", a.len(), a[99999]);
    for i in 0..100000i64 {
        r.a.push(i);
        r.a.push(i);
    }
    println!("array field {} {}", r.a.len(), r.a[199999]);
}
