use std::time::Duration;

use futures_util::{Stream, StreamExt};
use tokio::time::timeout;

use super::EventBus;

/// Long enough that a working bus always wins the race, short enough that a
/// broken one fails the test instead of hanging the suite.
const YIELD_TIMEOUT: Duration = Duration::from_secs(5);
/// How long we wait before concluding no further event is coming.
const IDLE_TIMEOUT: Duration = Duration::from_millis(100);

async fn next_event<S>(stream: &mut S) -> u32
where
    S: Stream<Item = u32> + Unpin,
{
    timeout(YIELD_TIMEOUT, stream.next())
        .await
        .expect("timed out waiting for an event")
        .expect("stream ended early")
}

async fn assert_idle<S>(stream: &mut S)
where
    S: Stream<Item = u32> + Unpin,
{
    assert!(
        timeout(IDLE_TIMEOUT, stream.next()).await.is_err(),
        "stream yielded an unexpected event"
    );
}

/// A subscriber sees everything published before it existed, in order,
/// followed by everything published after.
#[tokio::test]
async fn subscriber_replays_history_then_streams_live_events() {
    let bus = EventBus::new(16, 16);
    bus.publish(1).await;
    bus.publish(2).await;

    let mut stream = bus.subscribe();
    assert_eq!(next_event(&mut stream).await, 1);
    assert_eq!(next_event(&mut stream).await, 2);
    assert_idle(&mut stream).await;

    bus.publish(3).await;
    assert_eq!(next_event(&mut stream).await, 3);
}

/// History is a window on the most recent events: once it is full, each
/// publish drops the oldest event off the front.
#[tokio::test]
async fn history_evicts_oldest_past_the_limit() {
    let bus = EventBus::new(16, 3);
    for event in 1..=5 {
        bus.publish(event).await;
    }

    let mut stream = bus.subscribe();
    assert_eq!(next_event(&mut stream).await, 3);
    assert_eq!(next_event(&mut stream).await, 4);
    assert_eq!(next_event(&mut stream).await, 5);
    assert_idle(&mut stream).await;
}

/// Clearing history hides past events from future subscribers without
/// closing the bus.
#[tokio::test]
async fn clear_history_drops_the_replay_only() {
    let bus = EventBus::new(16, 16);
    bus.publish(1).await;
    bus.publish(2).await;
    bus.clear_history().await;

    let mut stream = bus.subscribe();
    assert_idle(&mut stream).await;

    bus.publish(3).await;
    assert_eq!(next_event(&mut stream).await, 3);
}

/// An early subscriber gets the events live; one created afterwards gets
/// the same events out of history. Both end up with the same sequence.
#[tokio::test]
async fn early_and_late_subscribers_see_the_same_events() {
    let bus = EventBus::new(16, 16);

    let mut early = bus.subscribe();
    bus.publish(1).await;
    bus.publish(2).await;

    let mut late = bus.subscribe();

    for expected in 1..=2 {
        assert_eq!(next_event(&mut early).await, expected);
        assert_eq!(next_event(&mut late).await, expected);
    }

    // Neither sees anything a second time: `early` received both events on
    // the channel, `late` replayed both out of history, and no event
    // reached either subscriber by both routes.
    assert_idle(&mut early).await;
    assert_idle(&mut late).await;
}

/// An event published after `subscribe` is delivered once, no matter how
/// long the consumer takes to poll for the first time. `subscribe` captures
/// the history snapshot and the broadcast receiver together, so the event is
/// absent from the snapshot and arrives only on the channel.
///
/// Regression test: the receiver used to be taken eagerly while the snapshot
/// was deferred to the first poll, so anything published in that window
/// landed in both and was delivered twice.
#[tokio::test]
async fn events_published_after_subscribe_arrive_exactly_once() {
    let bus = EventBus::new(16, 16);
    let mut stream = bus.subscribe();

    // Give the subscription every chance to be caught mid-setup: the
    // guarantee has to hold even when the stream is not polled promptly.
    tokio::task::yield_now().await;
    bus.publish(1).await;

    assert_eq!(next_event(&mut stream).await, 1);
    assert_idle(&mut stream).await;
}

/// The same guarantee under real contention: subscribing repeatedly while a
/// publisher runs on another thread must never hand a subscriber the same
/// event twice, whichever side of the history/channel boundary it lands on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_publishing_never_duplicates_for_new_subscribers() {
    // A short history keeps the replay/live boundary — where a duplicate
    // would show up — within the first few events each subscriber reads.
    let bus = EventBus::new(1024, 4);

    let publisher = tokio::spawn({
        let bus = bus.clone();
        async move {
            for event in 1..=500u32 {
                bus.publish(event).await;
                tokio::task::yield_now().await;
            }
        }
    });

    for _ in 0..100 {
        let mut stream = bus.subscribe();
        tokio::task::yield_now().await;

        let mut seen = Vec::new();
        for _ in 0..10 {
            match timeout(IDLE_TIMEOUT, stream.next()).await {
                Ok(Some(event)) => seen.push(event),
                _ => break,
            }
        }

        // A duplicate shows up as a repeat at the boundary, a re-run of the
        // replayed tail as a decrease. Strict monotonicity rules out both.
        assert!(
            seen.windows(2).all(|pair| pair[0] < pair[1]),
            "subscriber saw a repeated or reordered event: {seen:?}"
        );
    }

    publisher.await.expect("publisher panicked");
}

/// A subscriber that falls further behind than the channel capacity makes
/// the broadcast receiver report `Lagged`. Dropping events is acceptable
/// for a UI; silently ending the stream is not, so the invariant is that
/// the subscriber keeps receiving after the overflow.
#[tokio::test]
async fn lagging_subscriber_skips_events_but_stays_alive() {
    // `history_limit` of 0 keeps history empty, so everything read from the
    // stream comes through the broadcast channel rather than the replay.
    let bus = EventBus::new(2, 0);
    let mut stream = bus.subscribe();

    // Overflow the channel by publishing without reading.
    for event in 1..=5 {
        bus.publish(event).await;
    }
    bus.publish(6).await;

    let mut received = Vec::new();
    while received.last() != Some(&6) {
        received.push(next_event(&mut stream).await);
    }

    assert!(
        received.len() < 6,
        "expected the overflow to drop events, got {received:?}"
    );
    assert!(
        received.windows(2).all(|pair| pair[0] < pair[1]),
        "surviving events should stay in order, got {received:?}"
    );

    // Still usable after the lag.
    bus.publish(7).await;
    assert_eq!(next_event(&mut stream).await, 7);
}
