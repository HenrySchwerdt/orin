fn main() {
    let mut s = String::new();
    for i in 0..500000i64 {
        s.push_str("item");
        s.push_str(&i.to_string());
        s.push(',');
    }
    let parts: Vec<&str> = s.split(',').collect();
    let joined = parts.join(";");
    let (mut sum, mut non_empty) = (0i64, 0i64);
    for p in &parts {
        if !p.is_empty() {
            sum += p[4..].parse::<i64>().unwrap();
            non_empty += 1;
        }
    }
    println!("len {}", s.len());
    println!("parts {} nonEmpty {}", parts.len(), non_empty);
    println!("joined {}", joined.len());
    println!("sum {}", sum);
}
