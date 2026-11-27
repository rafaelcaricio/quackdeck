use std::time::Duration;

use duck_auth::tcp::{app_handshake, proxy};
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use tokio::net::TcpStream;
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tokio::time::{Instant, timeout, timeout_at};
use tokio_tungstenite::tungstenite::Message;

use crate::setup_code::decode_psk_hex;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SignallingEvent {
    Message { text: String },
    Closed { reason: String },
    Timeout,
}

/// Authenticated WebSocket signalling client running inside `duck-gateway`'s Noise tunnel on `:9443`.
pub struct LanSignallingClient {
    tx: mpsc::UnboundedSender<String>,
    rx: Mutex<mpsc::UnboundedReceiver<SignallingEvent>>,
    tasks: Vec<JoinHandle<()>>,
}

impl LanSignallingClient {
    pub async fn connect(
        host: &str,
        port: u16,
        robot_id: &str,
        psk_hex: &str,
        timeout_ms: u64,
    ) -> Result<Self, String> {
        let psk = decode_psk_hex(psk_hex)?;
        let addr = format!("{host}:{port}");
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);

        let mut stream = timeout_at(deadline, TcpStream::connect(&addr))
            .await
            .map_err(|_| format!("Timed out connecting to {addr}"))?
            .map_err(|e| format!("Failed connecting to {addr}: {e}"))?;
        let _ = stream.set_nodelay(true);

        let session = timeout_at(deadline, app_handshake(&mut stream, &psk, robot_id))
            .await
            .map_err(|_| format!("Timed out authenticating signalling on {addr}"))?
            .map_err(|e| format!("Signalling Noise authentication failed: {e}"))?;

        let (local, proxy_half) = tokio::io::duplex(64 * 1024);
        let proxy_task = tokio::spawn(async move {
            let _ = proxy(proxy_half, stream, session).await;
        });

        let (ws_stream, _) = timeout_at(
            deadline,
            tokio_tungstenite::client_async("ws://microduck/", local),
        )
        .await
        .map_err(|_| "Timed out during WebSocket signalling upgrade".to_owned())?
        .map_err(|e| format!("WebSocket signalling upgrade failed: {e}"))?;

        let (mut ws_sink, mut ws_source) = ws_stream.split();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
        let (ev_tx, ev_rx) = mpsc::unbounded_channel::<SignallingEvent>();

        let ev_tx_write = ev_tx.clone();
        let write_task = tokio::spawn(async move {
            while let Some(text) = out_rx.recv().await {
                if let Err(err) = ws_sink.send(Message::Text(text.into())).await {
                    let _ = ev_tx_write.send(SignallingEvent::Closed {
                        reason: format!("Signalling write error: {err}"),
                    });
                    break;
                }
            }
            let _ = ws_sink.close().await;
        });

        let read_task = tokio::spawn(async move {
            while let Some(item) = ws_source.next().await {
                match item {
                    Ok(Message::Text(text)) => {
                        let _ = ev_tx.send(SignallingEvent::Message {
                            text: text.to_string(),
                        });
                    }
                    Ok(Message::Binary(bytes)) => {
                        if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                            let _ = ev_tx.send(SignallingEvent::Message { text });
                        }
                    }
                    Ok(Message::Close(frame)) => {
                        let reason = frame
                            .map(|f| f.reason.to_string())
                            .filter(|s| !s.is_empty())
                            .unwrap_or_else(|| "Signalling closed by robot".to_owned());
                        let _ = ev_tx.send(SignallingEvent::Closed { reason });
                        return;
                    }
                    Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_)) => {}
                    Err(err) => {
                        let _ = ev_tx.send(SignallingEvent::Closed {
                            reason: format!("Signalling read error: {err}"),
                        });
                        return;
                    }
                }
            }
            let _ = ev_tx.send(SignallingEvent::Closed {
                reason: "Signalling stream ended".to_owned(),
            });
        });

        Ok(Self {
            tx: out_tx,
            rx: Mutex::new(ev_rx),
            tasks: vec![proxy_task, write_task, read_task],
        })
    }

    pub fn send_text(&self, text: String) -> Result<(), String> {
        self.tx
            .send(text)
            .map_err(|_| "Signalling channel is closed".to_owned())
    }

    pub async fn next_event(&self, timeout_ms: u64) -> SignallingEvent {
        let fut = async {
            let mut rx = self.rx.lock().await;
            rx.recv().await
        };
        match timeout(Duration::from_millis(timeout_ms), fut).await {
            Ok(Some(event)) => event,
            Ok(None) => SignallingEvent::Closed {
                reason: "Signalling closed".to_owned(),
            },
            Err(_) => SignallingEvent::Timeout,
        }
    }
}

impl Drop for LanSignallingClient {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use duck_auth::tcp::robot_handshake;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn websocket_signalling_runs_over_noise_tcp_tunnel() {
        let psk = [0x44u8; 32];
        let psk_hex = "44".repeat(32);
        let robot_id = "duck-932e";

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let session = robot_handshake(&mut socket, &psk, robot_id).await.unwrap();
            let (local, proxy_half) = tokio::io::duplex(64 * 1024);
            let _proxy = tokio::spawn(async move {
                let _ = proxy(proxy_half, socket, session).await;
            });
            let mut ws = tokio_tungstenite::accept_async(local).await.unwrap();
            ws.send(Message::Text(r#"{"type":"welcome","peerId":"p1"}"#.into()))
                .await
                .unwrap();
            let incoming = ws.next().await.unwrap().unwrap();
            assert_eq!(incoming.into_text().unwrap(), r#"{"type":"list"}"#);
            ws.send(Message::Text(
                r#"{"type":"list","producers":[{"id":"prod1","meta":{"name":"microduck"}}]}"#.into(),
            ))
            .await
            .unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
        });

        let sig = LanSignallingClient::connect("127.0.0.1", port, robot_id, &psk_hex, 2000)
            .await
            .unwrap();

        match sig.next_event(2000).await {
            SignallingEvent::Message { text } => assert!(text.contains("welcome")),
            other => panic!("unexpected event: {other:?}"),
        }

        sig.send_text(r#"{"type":"list"}"#.to_owned()).unwrap();

        match sig.next_event(2000).await {
            SignallingEvent::Message { text } => assert!(text.contains("prod1")),
            other => panic!("unexpected event: {other:?}"),
        }

        drop(sig);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn signalling_next_event_times_out_under_contention() {
        let psk = [0x45u8; 32];
        let psk_hex = "45".repeat(32);
        let robot_id = "duck-932e";

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let session = robot_handshake(&mut socket, &psk, robot_id).await.unwrap();
            let (local, proxy_half) = tokio::io::duplex(64 * 1024);
            let _proxy = tokio::spawn(async move {
                let _ = proxy(proxy_half, socket, session).await;
            });
            let _ws = tokio_tungstenite::accept_async(local).await.unwrap();
            tokio::time::sleep(Duration::from_millis(300)).await;
        });

        let sig = LanSignallingClient::connect("127.0.0.1", port, robot_id, &psk_hex, 2000)
            .await
            .unwrap();

        let (e1, e2) = tokio::join!(sig.next_event(60), sig.next_event(60));
        assert!(matches!(e1, SignallingEvent::Timeout));
        assert!(matches!(e2, SignallingEvent::Timeout));

        drop(sig);
        server.await.unwrap();
    }
}
