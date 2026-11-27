use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use duck_auth::wire::{Frame, MAX_CLIENT_LINE, MAX_ROBOT_LINE};
use duck_auth::{ClientConfirm, ClientStart, Session};
use duck_ble::framing::{FLOOR_MTU, MAX_ATTRIBUTE_VALUE, Reassembler, chunks};
use serde::Serialize;

use crate::setup_code::decode_psk_hex;

enum State {
    AwaitingChallenge(ClientStart),
    AwaitingReady(ClientConfirm),
    Open(Session),
    Closed,
}

pub struct BleNoiseSession {
    reassembler: Reassembler,
    state: State,
}

#[derive(Debug, Clone, Serialize)]
pub struct BleStepOutput {
    pub ready: bool,
    pub outbound_chunks_b64: Vec<String>,
    pub inbound_messages: Vec<String>,
}

fn clamp_write_mtu(mtu: usize) -> usize {
    mtu.clamp(FLOOR_MTU, MAX_ATTRIBUTE_VALUE)
}

fn encode_frame_chunks(frame: &Frame, mtu: usize) -> Result<Vec<String>, String> {
    let line = frame
        .encode(MAX_CLIENT_LINE)
        .map_err(|e| format!("BLE frame encode failed: {e:?}"))?;
    Ok(chunks(&line, clamp_write_mtu(mtu))
        .into_iter()
        .map(|chunk| STANDARD.encode(chunk))
        .collect())
}

impl BleNoiseSession {
    pub fn begin(psk_hex: &str, robot_id: &str, mtu: usize) -> Result<(Self, Vec<String>), String> {
        let psk = decode_psk_hex(psk_hex)?;
        let (client, start_bytes) =
            ClientStart::begin(&psk, robot_id).map_err(|e| format!("Noise start failed: {e:?}"))?;
        let start_chunks = encode_frame_chunks(&Frame::Start(start_bytes), mtu)?;
        let session = Self {
            reassembler: Reassembler::for_replies(),
            state: State::AwaitingChallenge(client),
        };
        Ok((session, start_chunks))
    }

    pub fn is_open(&self) -> bool {
        matches!(self.state, State::Open(_))
    }

    pub fn feed_chunk(&mut self, chunk: &[u8], mtu: usize) -> Result<BleStepOutput, String> {
        let lines = self
            .reassembler
            .push(chunk)
            .map_err(|e| format!("BLE reassembly error: {e}"))?;

        let mut outbound_chunks_b64 = Vec::new();
        let mut inbound_messages = Vec::new();

        for line in lines {
            let frame = Frame::decode(&line, MAX_ROBOT_LINE).map_err(|e| {
                self.state = State::Closed;
                format!("Invalid secure BLE frame: {e:?}")
            })?;
            let current = std::mem::replace(&mut self.state, State::Closed);
            match (current, frame) {
                (State::AwaitingChallenge(client), Frame::Challenge(bytes)) => {
                    let (confirm_state, proof) = client
                        .receive(&bytes)
                        .map_err(|e| format!("Robot Noise challenge failed: {e:?}"))?;
                    outbound_chunks_b64.extend(encode_frame_chunks(&Frame::Confirm(proof), mtu)?);
                    self.state = State::AwaitingReady(confirm_state);
                }
                (State::AwaitingReady(client), Frame::Ready(bytes)) => {
                    let transport = client
                        .receive(&bytes)
                        .map_err(|e| format!("Robot key confirmation failed: {e:?}"))?;
                    self.state = State::Open(transport);
                }
                (State::Open(mut transport), Frame::Data(bytes)) => {
                    let plaintext = transport
                        .open(&bytes)
                        .map_err(|e| format!("BLE decrypt failed: {e:?}"))?;
                    let text = String::from_utf8(plaintext)
                        .map_err(|_| "BLE decrypted message is not UTF-8".to_owned())?;
                    inbound_messages.push(text);
                    self.state = State::Open(transport);
                }
                _ => {
                    return Err("Unexpected BLE Noise frame for current handshake state".to_owned());
                }
            }
        }

        Ok(BleStepOutput {
            ready: self.is_open(),
            outbound_chunks_b64,
            inbound_messages,
        })
    }

    pub fn seal_json_line(&mut self, json_line: &str, mtu: usize) -> Result<Vec<String>, String> {
        let State::Open(ref mut transport) = self.state else {
            return Err("BLE Noise session is not ready".to_owned());
        };
        let ciphertext = transport.seal(json_line.as_bytes()).map_err(|e| {
            self.state = State::Closed;
            format!("BLE encrypt failed: {e:?}")
        })?;
        encode_frame_chunks(&Frame::Data(ciphertext), mtu)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use duck_auth::RobotConfirm;

    fn decode_b64_chunks(chunks: &[String]) -> Vec<Vec<u8>> {
        chunks
            .iter()
            .map(|c| STANDARD.decode(c).unwrap())
            .collect()
    }

    #[test]
    fn full_ble_noise_handshake_and_rpc_round_trip() {
        let psk = [0x5au8; 32];
        let psk_hex = "5a".repeat(32);
        let robot_id = "duck-932e";

        let (mut phone, start_b64) = BleNoiseSession::begin(&psk_hex, robot_id, 20).unwrap();
        assert!(!phone.is_open());

        let mut robot_rx = Reassembler::new();
        let mut lines = Vec::new();
        for c in decode_b64_chunks(&start_b64) {
            lines.extend(robot_rx.push(&c).unwrap());
        }
        assert_eq!(lines.len(), 1);
        let Frame::Start(start_bytes) = Frame::decode(&lines[0], MAX_CLIENT_LINE).unwrap() else {
            panic!("expected start frame");
        };

        let (robot_confirm, challenge) =
            RobotConfirm::respond(&psk, robot_id, &start_bytes).unwrap();
        let challenge_line = Frame::Challenge(challenge).encode(MAX_ROBOT_LINE).unwrap();

        let mut confirm_b64 = Vec::new();
        for c in chunks(&challenge_line, 20) {
            let out = phone.feed_chunk(&c, 20).unwrap();
            assert!(!out.ready);
            confirm_b64.extend(out.outbound_chunks_b64);
        }
        assert!(!confirm_b64.is_empty());

        let mut confirm_lines = Vec::new();
        for c in decode_b64_chunks(&confirm_b64) {
            confirm_lines.extend(robot_rx.push(&c).unwrap());
        }
        let Frame::Confirm(proof) = Frame::decode(&confirm_lines[0], MAX_CLIENT_LINE).unwrap()
        else {
            panic!("expected confirm frame");
        };

        let (mut robot_session, ready_bytes) = robot_confirm.receive(&proof).unwrap();
        let ready_line = Frame::Ready(ready_bytes).encode(MAX_ROBOT_LINE).unwrap();
        let mut became_ready = false;
        for c in chunks(&ready_line, 20) {
            let out = phone.feed_chunk(&c, 20).unwrap();
            became_ready |= out.ready;
        }
        assert!(became_ready);
        assert!(phone.is_open());

        // App sends RPC request
        let req = r#"{"jsonrpc":"2.0","id":1,"method":"system.info","params":{}}"#;
        let req_b64 = phone.seal_json_line(req, 185).unwrap();
        let mut req_lines = Vec::new();
        for c in decode_b64_chunks(&req_b64) {
            req_lines.extend(robot_rx.push(&c).unwrap());
        }
        let Frame::Data(ct) = Frame::decode(&req_lines[0], MAX_CLIENT_LINE).unwrap() else {
            panic!("expected data");
        };
        assert_eq!(robot_session.open(&ct).unwrap(), req.as_bytes());

        // Robot sends RPC reply
        let reply = r#"{"jsonrpc":"2.0","id":1,"result":{"name":"microduck"}}"#;
        let reply_ct = robot_session.seal(reply.as_bytes()).unwrap();
        let reply_line = Frame::Data(reply_ct).encode(MAX_ROBOT_LINE).unwrap();
        let mut received = Vec::new();
        for c in chunks(&reply_line, 20) {
            let out = phone.feed_chunk(&c, 20).unwrap();
            received.extend(out.inbound_messages);
        }
        assert_eq!(received, vec![reply.to_owned()]);
    }
}
