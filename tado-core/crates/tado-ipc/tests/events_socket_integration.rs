//! Integration test for A6's real-time event socket.
//!
//! Runs in its own process (as all Cargo integration tests do) so the
//! process-global `OnceLock` guards inside `events_socket` don't clash
//! with the unit-test module.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

#[test]
fn subscribe_and_receive_published_event() {
    // macOS caps Unix-domain socket paths at 104 bytes (SUN_LEN).
    // `std::env::temp_dir()` on mac returns something like
    // `/var/folders/.../T/` which already eats ~45 bytes — adding a
    // uuid dir + filename blows the limit. Pin to a short `/tmp`
    // path and suffix a short random so parallel test runs don't
    // collide.
    let short_id = uuid::Uuid::new_v4().simple().to_string();
    let short_id = &short_id[..8];
    let dir = std::path::PathBuf::from(format!("/tmp/tado-et-{short_id}"));
    std::fs::create_dir_all(&dir).unwrap();
    let sock_path = dir.join("e.sock");

    tado_ipc::start_events_server(&sock_path).expect("server starts");

    // Block until the socket file materializes (happens on the
    // accept-loop task spawned inside start; give it up to 1 s).
    let deadline = Instant::now() + Duration::from_secs(1);
    while !sock_path.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(sock_path.exists(), "events socket never bound");

    let mut stream = UnixStream::connect(&sock_path).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    stream
        .write_all(b"SUBSCRIBE *\n")
        .expect("send subscribe");

    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut ack = String::new();
    reader.read_line(&mut ack).expect("read ack");
    assert!(
        ack.contains(r#""type":"subscribed""#),
        "unexpected ack: {ack:?}"
    );
    assert!(ack.contains(r#""filter":"*""#), "unexpected ack: {ack:?}");

    // Give the subscriber task a moment to register with the
    // broadcast channel before we publish.
    std::thread::sleep(Duration::from_millis(50));
    tado_ipc::publish_event(
        "terminal.spawned",
        serde_json::json!({"sessionID": "abc-123", "pid": 999}),
    );

    let mut event = String::new();
    reader.read_line(&mut event).expect("read event");
    assert!(event.contains(r#""kind":"terminal.spawned""#), "got: {event}");
    assert!(event.contains(r#""session":"abc-123""#), "got: {event}");
    assert!(event.contains(r#""pid":999"#), "got: {event}");

    // Session filter should exclude events with a different session.
    let mut stream2 = UnixStream::connect(&sock_path).expect("connect 2");
    stream2
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    stream2
        .write_all(b"SUBSCRIBE session:different\n")
        .expect("send sub2");
    let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
    let mut ack2 = String::new();
    reader2.read_line(&mut ack2).expect("ack2");
    std::thread::sleep(Duration::from_millis(50));
    tado_ipc::publish_event(
        "terminal.spawned",
        serde_json::json!({"sessionID": "abc-123"}),
    );
    // Reader 2 should time out (no matching event); reader 1 should
    // receive it.
    let mut line2 = String::new();
    assert!(reader2.read_line(&mut line2).is_err() || line2.is_empty());
    let mut event_again = String::new();
    reader.read_line(&mut event_again).expect("reader 1 gets it");
    assert!(event_again.contains(r#""session":"abc-123""#));

    let _ = std::fs::remove_dir_all(&dir);
}
