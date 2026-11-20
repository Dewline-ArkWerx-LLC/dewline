//! Two endpoints in one process over loopback, no relay: the host, a guest,
//! and the whole life of a share between them.

use std::sync::Condvar;

use super::*;

/// How many times a session told its app something changed.
#[derive(Clone, Default)]
struct Heard(Arc<(Mutex<usize>, Condvar)>);

impl Listener for Heard {
    fn changed(&self) {
        let (count, change) = &*self.0;
        *lock(count) += 1;
        change.notify_all();
    }
}

impl Heard {
    fn get(&self) -> usize {
        *lock(&self.0.0)
    }

    /// Waits on the session's changes until `condition` holds. 15 s with no
    /// change fails rather than hangs.
    fn until(&self, what: &str, mut condition: impl FnMut() -> bool) {
        let (count, change) = &*self.0;
        let mut count = lock(count);
        while !condition() {
            let (next, wait) = change
                .wait_timeout(count, Duration::from_secs(15))
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            assert!(!wait.timed_out(), "timed out waiting for {what}");
            count = next;
        }
    }
}

fn host(text: &str, listener: Heard) -> Session {
    Session::host_on(
        Net::Loopback,
        new_node_key(),
        "Rick",
        "notes/plan.md",
        text,
        Box::new(listener),
    )
    .unwrap()
}

fn join(link: &str, name: &str, listener: Heard) -> Session {
    Session::join_on(
        Net::Loopback,
        new_node_key(),
        name,
        link,
        Box::new(listener),
    )
    .unwrap()
}

/// The first link, which waits for the host's own address.
fn invite(host: &Session) -> String {
    let link = host.invite().unwrap();
    assert!(link.contains("addr=127.0.0.1"), "{link}");
    link
}

/// The view of `session` after the next remote edit.
fn pulled(session: &Session, heard: &Heard, what: &str) -> RemoteEdit {
    let mut edit = None;
    heard.until(what, || {
        edit = session.pull();
        edit.is_some()
    });
    edit.unwrap()
}

#[test]
fn a_guest_asks_is_approved_edits_both_ways_and_is_removed() {
    let (host_heard, guest_heard) = (Heard::default(), Heard::default());
    let host = host("Ship on Friday.\n", host_heard.clone());
    let link = invite(&host);
    let guest = join(&link, "Ana", guest_heard.clone());

    host_heard.until("the join request", || host.pending().len() == 1);
    assert!(host_heard.get() > 0, "the host's app hears of the request");
    assert_eq!(guest.status(), Status::Waiting);
    assert_eq!(guest.host_name(), "Rick", "the guest's wait names the host");
    let ana = host.pending().remove(0);
    assert_eq!(ana.name, "Ana");

    let key = host.document_key();
    host.approve(&ana.id);
    assert_ne!(host.document_key(), key, "approval rotates the key");
    guest_heard.until("the guest to go live", || guest.status() == Status::Live);
    assert_eq!(guest.text(), "Ship on Friday.\n");
    assert_eq!(guest.file_name(), "plan.md");
    assert_eq!(guest.document_key(), host.document_key());
    assert_eq!(host.peers(), vec![ana.clone()]);
    assert_eq!(guest.peers().len(), 1);

    guest.edit(8, 14, "Monday").unwrap();
    let edit = pulled(&host, &host_heard, "the guest's edit at the host");
    assert_eq!((edit.start, edit.end), (8, 11));
    assert_eq!((edit.text.as_str(), edit.name.as_str()), ("Mon", "Ana"));
    assert_eq!(host.text(), "Ship on Monday.\n");

    host.edit(0, 0, "# Plan\n").unwrap();
    let edit = pulled(&guest, &guest_heard, "the host's edit at the guest");
    assert_eq!(
        (edit.start, edit.end, edit.text.as_str()),
        (0, 0, "# Plan\n")
    );
    assert_eq!(guest.text(), "# Plan\nShip on Monday.\n");

    let key = host.document_key();
    host.remove(&ana.id);
    assert_ne!(host.document_key(), key, "removal rotates the key");
    guest_heard.until("the guest to hear it was removed", || {
        guest.status() == Status::Removed
    });
    assert!(host.peers().is_empty());
    assert_ne!(
        guest.document_key(),
        host.document_key(),
        "a removed guest cannot open what the host seals now"
    );
    host.edit(0, 0, "Secret. ").unwrap();
    assert_eq!(guest.pull(), None, "a removed guest gets nothing new");
    host.close();
    guest.close();
}

#[test]
fn a_link_admits_one_join_and_a_denied_guest_hears_it() {
    let (host_heard, first_heard, second_heard) =
        (Heard::default(), Heard::default(), Heard::default());
    let host = host("Plan\n", host_heard.clone());
    let link = invite(&host);
    let first = join(&link, "Ana", first_heard.clone());
    host_heard.until("the first request", || host.pending().len() == 1);
    let second = join(&link, "Mallory", second_heard.clone());
    second_heard.until("the spent link to be refused", || {
        second.status() == Status::Denied
    });
    assert_eq!(host.pending().len(), 1);
    host.deny(&host.pending()[0].id);
    first_heard.until("the denial", || first.status() == Status::Denied);
    assert!(host.peers().is_empty());
    host.close();
    first.close();
    second.close();
}
