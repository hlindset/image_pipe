// Records the resolved resvg version from Cargo.lock, which ImagePipe puts in
// the cache key: a new resvg can render the same SVG differently.
fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    let lock = std::fs::read_to_string("Cargo.lock").expect("Cargo.lock is committed");
    let version = lock
        .split("[[package]]")
        .find_map(|entry| {
            let mut lines = entry.lines().map(str::trim);
            lines.find(|line| *line == r#"name = "resvg""#)?;
            lines
                .find_map(|line| line.strip_prefix("version = "))
                .map(|value| value.trim_matches('"').to_owned())
        })
        .expect("Cargo.lock lists resvg");
    println!("cargo:rustc-env=RESVG_VERSION={version}");
}
