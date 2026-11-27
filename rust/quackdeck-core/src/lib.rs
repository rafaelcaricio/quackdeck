pub mod adv;
pub mod ble_session;
pub mod lan_rpc;
pub mod lan_signalling;
pub mod setup_code;

use std::ffi::{CStr, CString, c_char};
use std::sync::{Mutex, OnceLock};

use serde::Serialize;
use tokio::runtime::Runtime;

use crate::ble_session::BleNoiseSession;
use crate::lan_rpc::LanRpcClient;
use crate::lan_signalling::LanSignallingClient;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("quackdeck-io")
            .build()
            .expect("failed to start tokio runtime")
    })
}

#[derive(Serialize)]
struct JsonResult<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn to_c_json<T: Serialize>(result: Result<T, String>) -> *mut c_char {
    let payload = match result {
        Ok(value) => serde_json::to_string(&JsonResult {
            ok: true,
            value: Some(value),
            error: None,
        }),
        Err(error) => serde_json::to_string(&JsonResult::<()> {
            ok: false,
            value: None,
            error: Some(error),
        }),
    }
    .unwrap_or_else(|_| r#"{"ok":false,"error":"serialization failed"}"#.to_owned());

    CString::new(payload)
        .unwrap_or_else(|_| CString::new(r#"{"ok":false,"error":"interior nul byte"}"#).unwrap())
        .into_raw()
}

unsafe fn read_c_str<'a>(ptr: *const c_char, name: &str) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err(format!("Null string pointer for {name}"));
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| format!("Invalid UTF-8 for {name}"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn qd_gatt_uuids() -> *mut c_char {
    to_c_json(Ok(adv::gatt_uuids()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_parse_cb_manufacturer_data(
    bytes: *const u8,
    len: usize,
) -> *mut c_char {
    let slice = if bytes.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    to_c_json(Ok(adv::parse_cb_manufacturer_data(slice)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_parse_setup_code(raw: *const c_char) -> *mut c_char {
    let result = unsafe { read_c_str(raw, "raw") }.and_then(setup_code::parse_setup_code);
    to_c_json(result)
}

// ── BLE Noise session ────────────────────────────────────────────────────────

pub struct QdBleSession(Mutex<BleNoiseSession>);

#[derive(Serialize)]
struct BleBeginOutput {
    outbound_chunks_b64: Vec<String>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_ble_session_new(
    psk_hex: *const c_char,
    robot_id: *const c_char,
    mtu: usize,
    out_handle: *mut *mut QdBleSession,
) -> *mut c_char {
    if out_handle.is_null() {
        return to_c_json::<BleBeginOutput>(Err("out_handle is null".to_owned()));
    }
    unsafe { *out_handle = std::ptr::null_mut() };
    let res = (|| {
        let psk = unsafe { read_c_str(psk_hex, "psk_hex") }?;
        let rid = unsafe { read_c_str(robot_id, "robot_id") }?;
        let (session, chunks) = BleNoiseSession::begin(psk, rid, mtu)?;
        let boxed = Box::new(QdBleSession(Mutex::new(session)));
        unsafe { *out_handle = Box::into_raw(boxed) };
        Ok(BleBeginOutput {
            outbound_chunks_b64: chunks,
        })
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_ble_session_feed(
    handle: *mut QdBleSession,
    bytes: *const u8,
    len: usize,
    mtu: usize,
) -> *mut c_char {
    let res = (|| {
        if handle.is_null() {
            return Err("BLE session handle is null".to_owned());
        }
        let slice = if bytes.is_null() || len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(bytes, len) }
        };
        let session = unsafe { &*handle };
        let mut guard = session
            .0
            .lock()
            .map_err(|_| "BLE session lock poisoned".to_owned())?;
        guard.feed_chunk(slice, mtu)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_ble_session_seal(
    handle: *mut QdBleSession,
    json_line: *const c_char,
    mtu: usize,
) -> *mut c_char {
    let res = (|| {
        if handle.is_null() {
            return Err("BLE session handle is null".to_owned());
        }
        let line = unsafe { read_c_str(json_line, "json_line") }?;
        let session = unsafe { &*handle };
        let mut guard = session
            .0
            .lock()
            .map_err(|_| "BLE session lock poisoned".to_owned())?;
        let chunks = guard.seal_json_line(line, mtu)?;
        Ok(BleBeginOutput {
            outbound_chunks_b64: chunks,
        })
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_ble_session_free(handle: *mut QdBleSession) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

// ── LAN RPC client (port 9444) ───────────────────────────────────────────────

pub struct QdLanRpcClient(LanRpcClient);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_lan_rpc_connect(
    host: *const c_char,
    port: u16,
    robot_id: *const c_char,
    psk_hex: *const c_char,
    timeout_ms: u64,
    out_handle: *mut *mut QdLanRpcClient,
) -> *mut c_char {
    if out_handle.is_null() {
        return to_c_json::<bool>(Err("out_handle is null".to_owned()));
    }
    unsafe { *out_handle = std::ptr::null_mut() };
    let res = (|| {
        let host = unsafe { read_c_str(host, "host") }?;
        let rid = unsafe { read_c_str(robot_id, "robot_id") }?;
        let psk = unsafe { read_c_str(psk_hex, "psk_hex") }?;
        let client = runtime().block_on(LanRpcClient::connect(host, port, rid, psk, timeout_ms))?;
        unsafe { *out_handle = Box::into_raw(Box::new(QdLanRpcClient(client))) };
        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_lan_rpc_call(
    handle: *mut QdLanRpcClient,
    request_json: *const c_char,
    timeout_ms: u64,
) -> *mut c_char {
    let res = (|| {
        if handle.is_null() {
            return Err("LAN RPC handle is null".to_owned());
        }
        let req = unsafe { read_c_str(request_json, "request_json") }?;
        let client = unsafe { &*handle };
        runtime().block_on(client.0.call(req, timeout_ms))
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_lan_rpc_free(handle: *mut QdLanRpcClient) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

// ── LAN WebRTC Signalling client (port 9443) ─────────────────────────────────

pub struct QdSignallingClient(LanSignallingClient);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_sig_connect(
    host: *const c_char,
    port: u16,
    robot_id: *const c_char,
    psk_hex: *const c_char,
    timeout_ms: u64,
    out_handle: *mut *mut QdSignallingClient,
) -> *mut c_char {
    if out_handle.is_null() {
        return to_c_json::<bool>(Err("out_handle is null".to_owned()));
    }
    unsafe { *out_handle = std::ptr::null_mut() };
    let res = (|| {
        let host = unsafe { read_c_str(host, "host") }?;
        let rid = unsafe { read_c_str(robot_id, "robot_id") }?;
        let psk = unsafe { read_c_str(psk_hex, "psk_hex") }?;
        let client = runtime().block_on(LanSignallingClient::connect(
            host, port, rid, psk, timeout_ms,
        ))?;
        unsafe { *out_handle = Box::into_raw(Box::new(QdSignallingClient(client))) };
        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_sig_send(
    handle: *mut QdSignallingClient,
    text: *const c_char,
) -> *mut c_char {
    let res = (|| {
        if handle.is_null() {
            return Err("Signalling handle is null".to_owned());
        }
        let text = unsafe { read_c_str(text, "text") }?;
        let client = unsafe { &*handle };
        client.0.send_text(text.to_owned())?;
        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_sig_next_event(
    handle: *mut QdSignallingClient,
    timeout_ms: u64,
) -> *mut c_char {
    let res = (|| {
        if handle.is_null() {
            return Err("Signalling handle is null".to_owned());
        }
        let client = unsafe { &*handle };
        Ok(runtime().block_on(client.0.next_event(timeout_ms)))
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qd_sig_free(handle: *mut QdSignallingClient) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}
