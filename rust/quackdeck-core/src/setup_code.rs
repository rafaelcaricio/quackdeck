use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ParsedSetupCode {
    pub robot_id: String,
    pub psk_hex: String,
}

/// Parse a Microduck setup code of the form `md1:<robot_id>:<64-hex-chars>`,
/// or a factory QR line prefixed with a label serial (`<serial>:md1:<robot_id>:<64-hex-chars>`).
pub fn parse_setup_code(raw: &str) -> Result<ParsedSetupCode, String> {
    let trimmed = raw.trim();
    let code = match trimmed.find("md1:") {
        Some(at) if at == 0 || trimmed.as_bytes()[at - 1] == b':' => &trimmed[at..],
        _ => return Err("Setup code must start with md1:<robot_id>:<64-hex-key>".to_owned()),
    };
    let mut parts = code.split(':');
    let scheme = parts.next().unwrap_or("");
    let robot_id = parts.next().unwrap_or("");
    let key_hex = parts.next().unwrap_or("");
    if scheme != "md1" || parts.next().is_some() {
        return Err("Setup code must start with md1:<robot_id>:<64-hex-key>".to_owned());
    }
    if robot_id.is_empty()
        || robot_id.len() > 128
        || !robot_id.is_ascii()
        || robot_id.bytes().any(|b| b.is_ascii_whitespace())
    {
        return Err("Setup code has an invalid robot identifier".to_owned());
    }
    let key = decode_psk_hex(key_hex)?;
    let mut normalized = String::with_capacity(64);
    for byte in key {
        normalized.push_str(&format!("{byte:02x}"));
    }
    Ok(ParsedSetupCode {
        robot_id: robot_id.to_owned(),
        psk_hex: normalized,
    })
}

pub fn decode_psk_hex(hex: &str) -> Result<[u8; 32], String> {
    let trimmed = hex.trim();
    if trimmed.len() != 64 || !trimmed.is_ascii() {
        return Err("Setup key must be exactly 64 hexadecimal characters".to_owned());
    }
    let mut key = [0u8; 32];
    for (idx, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&trimmed[idx * 2..idx * 2 + 2], 16)
            .map_err(|_| "Setup key contains non-hexadecimal characters".to_owned())?;
    }
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_md1_code_and_normalizes_hex() {
        let raw = format!("  md1:duck-932e:{} \n", "AB".repeat(32));
        let parsed = parse_setup_code(&raw).unwrap();
        assert_eq!(parsed.robot_id, "duck-932e");
        assert_eq!(parsed.psk_hex, "ab".repeat(32));
    }

    #[test]
    fn parses_factory_qr_prefixed_code() {
        let hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
        let raw = format!("  202004743264300098:md1:duck-ccf2:{hex}\n");
        let parsed = parse_setup_code(&raw).unwrap();
        assert_eq!(parsed.robot_id, "duck-ccf2");
        assert_eq!(parsed.psk_hex, hex);

        let multi_prefix = format!("factory:lot-7:md1:duck-ccf2:{}", "CD".repeat(32));
        let parsed_multi = parse_setup_code(&multi_prefix).unwrap();
        assert_eq!(parsed_multi.robot_id, "duck-ccf2");
        assert_eq!(parsed_multi.psk_hex, "cd".repeat(32));
    }

    #[test]
    fn rejects_malformed_codes() {
        let valid_hex = "00".repeat(32);
        assert!(parse_setup_code("md2:duck-932e:00").is_err());
        assert!(parse_setup_code(&format!("md2:duck-932e:{valid_hex}")).is_err());
        assert!(parse_setup_code(&format!("notmd1:duck-932e:{valid_hex}")).is_err());
        assert!(parse_setup_code(&format!("202004743264300098:md1::{valid_hex}")).is_err());
        assert!(parse_setup_code("md1::00").is_err());
        assert!(parse_setup_code(&format!("md1:duck-932e:{}", "zz".repeat(32))).is_err());
        assert!(parse_setup_code(&format!("md1:duck-932e:{valid_hex}:extra")).is_err());
        assert!(parse_setup_code(&format!("serial:md1:duck-932e:{valid_hex}:extra")).is_err());
        assert!(parse_setup_code(&valid_hex).is_err());
    }
}
