use std::time::Duration;

use duck_auth::tcp::{app_handshake, proxy};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, ReadHalf, WriteHalf};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tokio::time::{Instant, timeout_at};

use crate::setup_code::decode_psk_hex;

struct RpcIo {
    reader: BufReader<ReadHalf<tokio::io::DuplexStream>>,
    writer: WriteHalf<tokio::io::DuplexStream>,
}

/// Authenticated Noise TCP client for `duck-gateway` port `9444` (NDJSON JSON-RPC lane).
pub struct LanRpcClient {
    io: Mutex<RpcIo>,
    proxy_task: JoinHandle<()>,
}

impl LanRpcClient {
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
            .map_err(|_| format!("Timed out authenticating with {addr}"))?
            .map_err(|e| format!("Noise LAN authentication failed: {e}"))?;

        let (local, proxy_half) = tokio::io::duplex(64 * 1024);
        let proxy_task = tokio::spawn(async move {
            let _ = proxy(proxy_half, stream, session).await;
        });

        let (read_half, write_half) = tokio::io::split(local);
        Ok(Self {
            io: Mutex::new(RpcIo {
                reader: BufReader::new(read_half),
                writer: write_half,
            }),
            proxy_task,
        })
    }

    pub async fn call(&self, request_json: &str, timeout_ms: u64) -> Result<String, String> {
        let mut payload = request_json.trim_end_matches(['\r', '\n']).as_bytes().to_vec();
        payload.push(b'\n');
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);

        let mut io = timeout_at(deadline, self.io.lock())
            .await
            .map_err(|_| "Timed out waiting for LAN RPC lock".to_owned())?;

        timeout_at(deadline, async {
            io.writer
                .write_all(&payload)
                .await
                .map_err(|e| format!("LAN RPC write failed: {e}"))?;
            io.writer
                .flush()
                .await
                .map_err(|e| format!("LAN RPC flush failed: {e}"))?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|_| "Timed out writing LAN RPC request".to_owned())??;

        let mut line = String::new();
        let bytes = timeout_at(deadline, io.reader.read_line(&mut line))
            .await
            .map_err(|_| "Timed out waiting for LAN RPC reply".to_owned())?
            .map_err(|e| format!("LAN RPC read failed: {e}"))?;
        if bytes == 0 {
            return Err("LAN RPC connection closed by robot".to_owned());
        }
        Ok(line.trim_end_matches(['\r', '\n']).to_owned())
    }
}

impl Drop for LanRpcClient {
    fn drop(&mut self) {
        self.proxy_task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use duck_auth::tcp::robot_handshake;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn authenticated_lan_rpc_round_trip() {
        let psk = [0x33u8; 32];
        let psk_hex = "33".repeat(32);
        let robot_id = "duck-01";

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let session = robot_handshake(&mut socket, &psk, robot_id).await.unwrap();
            let (local, proxy_half) = tokio::io::duplex(16 * 1024);
            let _proxy = tokio::spawn(async move {
                let _ = proxy(proxy_half, socket, session).await;
            });
            let (r, mut w) = tokio::io::split(local);
            let mut br = BufReader::new(r);
            let mut line = String::new();
            br.read_line(&mut line).await.unwrap();
            assert!(line.contains("system.info"));
            w.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"name\":\"microduck\"}}\n")
                .await
                .unwrap();
            w.flush().await.unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
        });

        let client = LanRpcClient::connect("127.0.0.1", port, robot_id, &psk_hex, 2000)
            .await
            .unwrap();
        let reply = client
            .call(r#"{"jsonrpc":"2.0","id":1,"method":"system.info","params":{}}"#, 2000)
            .await
            .unwrap();
        assert!(reply.contains("microduck"));
        drop(client);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn lan_rpc_timeouts_cover_lock_and_unresponsive_peer() {
        let psk = [0x34u8; 32];
        let psk_hex = "34".repeat(32);
        let robot_id = "duck-01";

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let session = robot_handshake(&mut socket, &psk, robot_id).await.unwrap();
            let (local, proxy_half) = tokio::io::duplex(16 * 1024);
            let _proxy = tokio::spawn(async move {
                let _ = proxy(proxy_half, socket, session).await;
            });
            let (_r, _w) = tokio::io::split(local);
            tokio::time::sleep(Duration::from_millis(400)).await;
        });

        let client = LanRpcClient::connect("127.0.0.1", port, robot_id, &psk_hex, 2000)
            .await
            .unwrap();

        let (r1, r2) = tokio::join!(
            client.call(r#"{"jsonrpc":"2.0","id":1,"method":"system.info","params":{}}"#, 80),
            client.call(r#"{"jsonrpc":"2.0","id":2,"method":"robot.health","params":{}}"#, 80),
        );
        assert!(r1.is_err());
        assert!(r2.is_err());

        drop(client);
        server.await.unwrap();
    }
}
