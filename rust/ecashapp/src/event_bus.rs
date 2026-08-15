use futures_util::Stream;
use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::RwLock;

#[derive(Clone)]
pub struct EventBus<T>
where
    T: Clone + Send + Sync + 'static,
{
    history: Arc<RwLock<VecDeque<T>>>,
    tx: broadcast::Sender<T>,
    history_limit: usize,
}

impl<T> EventBus<T>
where
    T: Clone + Send + Sync + 'static,
{
    pub fn new(capacity: usize, history_limit: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self {
            history: Arc::new(RwLock::new(VecDeque::new())),
            tx,
            history_limit,
        }
    }

    /// Adds the event to history, removing old events if over history limit, then
    /// sends the event on the channel
    pub async fn publish(&self, event: T) {
        {
            let mut hist = self.history.write().await;
            hist.push_back(event.clone());

            if hist.len() > self.history_limit {
                hist.pop_front();
            }
        }

        let _ = self.tx.send(event);
    }

    /// Clears all events from history
    pub async fn clear_history(&self) {
        let mut hist = self.history.write().await;
        hist.clear();
    }

    /// Returns a stream that yields all events in history, then all future events
    /// until the channel is closed
    pub fn subscribe(&self) -> Pin<Box<impl Stream<Item = T> + Send + '_>> {
        let history_snapshot_fut = async {
            let history_guard = self.history.read().await;
            history_guard.clone()
        };

        let mut rx = self.tx.subscribe();

        let stream = async_stream::stream! {
            let history_clone = history_snapshot_fut.await;
            for event in history_clone {
                yield event;
            }

            loop {
                match rx.recv().await {
                    Ok(event) => yield event,
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        // since the EventBus is only consumed in the context of
                        // our UI, the impact of missing an event due to lagging behind
                        // is relatively harmless so we can continue
                        println!("Subscriber lagged, needed to skip {n} events");
                        continue;
                    }
                }
            }
        };

        Box::pin(stream)
    }
}

#[cfg(test)]
mod tests {
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
}
