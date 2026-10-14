fn main() {
    let s = "0123456789abcdef".repeat(65536);
    let mut total = 0usize;
    for round in 0..40usize {
        let b: Vec<u8> = s.as_bytes().to_vec();
        let t = unsafe { String::from_utf8_unchecked(b.clone()) };
        total += t.len() + t.as_bytes()[round * 7919] as usize + b[round] as usize;
    }
    println!("len {}", s.len());
    println!("total {}", total);
}
