use futures_util::Stream;
use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::{Arc, RwLock};
use tokio::sync::broadcast;

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
    /// sends the event on the channel.
    ///
    /// The send happens while the history lock is still held, so that appending
    /// to history and publishing to subscribers is a single step as far as
    /// [`Self::subscribe`] is concerned. Releasing the lock first would leave a
    /// window in which a new subscriber snapshots the event out of history *and*
    /// then receives it again on the channel.
    pub async fn publish(&self, event: T) {
        let mut hist = self.history.write().expect("history lock poisoned");
        hist.push_back(event.clone());

        if hist.len() > self.history_limit {
            hist.pop_front();
        }

        let _ = self.tx.send(event);
    }

    /// Clears all events from history
    pub async fn clear_history(&self) {
        let mut hist = self.history.write().expect("history lock poisoned");
        hist.clear();
    }

    /// Returns a stream that yields all events in history, then all future events
    /// until the channel is closed.
    ///
    /// The history snapshot and the broadcast receiver are taken together under
    /// the same lock, which is what makes delivery exactly-once: [`Self::publish`]
    /// cannot interleave, so every event is either already in the snapshot (and
    /// so predates the receiver) or is delivered on the channel (and so is absent
    /// from the snapshot), never both.
    pub fn subscribe(&self) -> Pin<Box<impl Stream<Item = T> + Send + 'static>> {
        let (history, mut rx) = {
            let hist = self.history.read().expect("history lock poisoned");
            (hist.clone(), self.tx.subscribe())
        };

        let stream = async_stream::stream! {
            for event in history {
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
mod tests;
