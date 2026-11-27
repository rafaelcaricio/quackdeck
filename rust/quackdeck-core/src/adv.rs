use std::collections::HashMap;

use duck_ble::{adv, gatt};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GattUuids {
    pub service_uuid: String,
    pub rpc_uuid: String,
    pub company_id: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AdvInfo {
    pub has_address_field: bool,
    pub ipv4: Option<String>,
    pub is_extended: bool,
    pub is_busy: bool,
}

pub fn gatt_uuids() -> GattUuids {
    GattUuids {
        service_uuid: gatt::SERVICE_UUID.to_string().to_uppercase(),
        rpc_uuid: gatt::RPC_UUID.to_string().to_uppercase(),
        company_id: adv::COMPANY_ID,
    }
}

/// Parse CoreBluetooth's `CBAdvertisementDataManufacturerDataKey` byte slice.
///
/// CoreBluetooth prepends the 2-byte little-endian Bluetooth SIG company identifier
/// before the manufacturer payload.
pub fn parse_cb_manufacturer_data(bytes: &[u8]) -> AdvInfo {
    if bytes.len() < 2 {
        return AdvInfo {
            has_address_field: false,
            ipv4: None,
            is_extended: false,
            is_busy: false,
        };
    }
    let company_id = u16::from_le_bytes([bytes[0], bytes[1]]);
    let payload = normalize_cb_payload(company_id, bytes[2..].to_vec());
    let map = HashMap::from([(company_id, payload)]);
    AdvInfo {
        has_address_field: adv::has_address_field(&map),
        ipv4: adv::address_in(&map).map(|ip| ip.to_string()),
        is_extended: adv::is_extended(&map),
        is_busy: adv::is_busy(&map),
    }
}

/// On boards with BlueZ device privacy disabled, CoreBluetooth reports legacy (4-byte)
/// and extended (5-byte) advertisements under one company ID as a 9-byte joined payload.
/// Normalize matching halves back to the 4-byte legacy payload for `duck-ble`.
fn normalize_cb_payload(company_id: u16, payload: Vec<u8>) -> Vec<u8> {
    if company_id != adv::COMPANY_ID || payload.len() != 9 {
        return payload;
    }
    match payload.as_slice() {
        [a, b, c, d, e, f, g, h, mark]
            if *mark == adv::EXTENDED_MARK && [a, b, c, d] == [e, f, g, h] =>
        {
            vec![*a, *b, *c, *d]
        }
        [a, b, c, d, mark, e, f, g, h]
            if *mark == adv::EXTENDED_MARK && [a, b, c, d] == [e, f, g, h] =>
        {
            vec![*a, *b, *c, *d]
        }
        _ => payload,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn cb_bytes(payload: Vec<u8>) -> Vec<u8> {
        let mut out = adv::COMPANY_ID.to_le_bytes().to_vec();
        out.extend(payload);
        out
    }

    #[test]
    fn parses_legacy_extended_busy_and_apple_joined_payloads() {
        let ip = Ipv4Addr::new(192, 0, 2, 10);

        let legacy = parse_cb_manufacturer_data(&cb_bytes(adv::address_data(Some(ip))));
        assert!(legacy.has_address_field);
        assert_eq!(legacy.ipv4.as_deref(), Some("192.0.2.10"));
        assert!(!legacy.is_extended);
        assert!(!legacy.is_busy);

        let ext = parse_cb_manufacturer_data(&cb_bytes(adv::extended_address_data(Some(ip))));
        assert_eq!(ext.ipv4.as_deref(), Some("192.0.2.10"));
        assert!(ext.is_extended);
        assert!(!ext.is_busy);

        let busy = parse_cb_manufacturer_data(&cb_bytes(adv::busy_address_data(Some(ip))));
        assert_eq!(busy.ipv4.as_deref(), Some("192.0.2.10"));
        assert!(busy.is_busy);
        assert!(!busy.is_extended);

        // Boards with BlueZ privacy off: CoreBluetooth joins legacy (4B) + extended (5B) = 9B.
        let mut joined = adv::address_data(Some(ip));
        joined.extend(adv::extended_address_data(Some(ip)));
        let joined_info = parse_cb_manufacturer_data(&cb_bytes(joined));
        assert!(joined_info.has_address_field);
        assert_eq!(joined_info.ipv4.as_deref(), Some("192.0.2.10"));
        assert!(!joined_info.is_busy);

        // No Wi-Fi (0.0.0.0) still sets has_address_field = true with ipv4 = None.
        let no_wifi = parse_cb_manufacturer_data(&cb_bytes(adv::address_data(None)));
        assert!(no_wifi.has_address_field);
        assert_eq!(no_wifi.ipv4, None);
    }
}
