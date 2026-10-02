// The guest `WasmWebViewHostTests` runs: one module, dispatched on argv[0].
//
// - `hello` prints a greeting from `$GREETING` and exits with argv[1].
// - `echo` sends stdin to `test.echo` and prints the reply.
// - `fail` calls `test.fail` and prints the error it was handed.
// - `count` calls `test.count` twice, so a test can see each call ran once.
// - `short` collects a reply into a buffer too small for it, then again.
// - `write` leaves `out.txt` in its working directory.
// - `streams` writes two lines to stdout and two to stderr, alternating.
//
// Rebuild with:
//     rustc --target wasm32-wasip1 -O -C strip=symbols -o guest.wasm guest.rs
use std::io::{self, Read, Write};

#[link(wasm_import_module = "test")]
extern "C" {
    fn echo(ptr: *const u8, len: usize) -> i32;
    fn fail(ptr: *const u8, len: usize) -> i32;
    fn count(ptr: *const u8, len: usize) -> i32;
}

#[link(wasm_import_module = "wasm_host")]
extern "C" {
    fn take_reply(ptr: *mut u8, capacity: usize) -> i32;
}

/// Calls a host function the documented way: the return value is the
/// reply's length, or `-(length + 1)` for an error message.
fn call(function: unsafe extern "C" fn(*const u8, usize) -> i32, request: &[u8]) -> Result<Vec<u8>, String> {
    let status = unsafe { function(request.as_ptr(), request.len()) };
    let length = if status >= 0 { status } else { -status - 1 } as usize;
    let mut reply = vec![0u8; length];
    let copied = unsafe { take_reply(reply.as_mut_ptr(), length) } as usize;
    reply.truncate(copied);
    if status >= 0 {
        Ok(reply)
    } else {
        Err(String::from_utf8_lossy(&reply).into_owned())
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let argv0 = args.first().cloned().unwrap_or_default();
    let mut out = io::stdout();

    match argv0.as_str() {
        "hello" => {
            let greeting = std::env::var("GREETING").unwrap_or_else(|_| "unset".into());
            writeln!(out, "hello {greeting}").unwrap();
            let code = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(0);
            std::process::exit(code);
        }
        "echo" => {
            let mut input = Vec::new();
            io::stdin().read_to_end(&mut input).unwrap();
            let reply = call(echo, &input).unwrap();
            out.write_all(&reply).unwrap();
        }
        "fail" => match call(fail, b"anything") {
            Ok(_) => writeln!(out, "unexpected reply").unwrap(),
            Err(message) => {
                writeln!(out, "error={message}").unwrap();
                std::process::exit(3);
            }
        },
        "count" => {
            for _ in 0..2 {
                let reply = call(count, b"").unwrap();
                writeln!(out, "{}", String::from_utf8_lossy(&reply)).unwrap();
            }
        }
        "short" => {
            let status = unsafe { echo(b"abcdef".as_ptr(), 6) };
            let mut buffer = [0u8; 3];
            let first = unsafe { take_reply(buffer.as_mut_ptr(), buffer.len()) };
            let second = unsafe { take_reply(buffer.as_mut_ptr(), buffer.len()) };
            writeln!(
                out,
                "status={status} first={first} {} second={second}",
                String::from_utf8_lossy(&buffer[..first as usize])
            )
            .unwrap();
        }
        "write" => {
            std::fs::write("out.txt", b"from the guest\n").unwrap();
        }
        "streams" => {
            let mut err = io::stderr();
            for n in 1..=2 {
                writeln!(out, "out{n}").unwrap();
                out.flush().unwrap();
                writeln!(err, "err{n}").unwrap();
            }
        }
        other => {
            eprintln!("unknown applet {other}");
            std::process::exit(2);
        }
    }
}
