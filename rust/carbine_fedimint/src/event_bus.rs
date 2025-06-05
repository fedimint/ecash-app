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
