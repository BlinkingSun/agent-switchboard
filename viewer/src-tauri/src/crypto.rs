//! Command-channel crypto — byte-for-byte match with hub/exec/crypto.py + hub/pair/crypto.py.

use std::collections::BTreeMap;

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use hmac::{Hmac, Mac};
use hkdf::Hkdf;
use serde_json::{Map, Value};
use sha2::Sha256;

const HKDF_SALT: &[u8] = b"overwatch/cmd/v1";
const SECRET_LEN: usize = 32;
const IV_LEN: usize = 12;
const TAG_LEN: usize = 16;

type HmacSha256 = Hmac<Sha256>;

pub fn b64url_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

pub fn b64url_decode(data: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(data)
        .map_err(|e| format!("base64url decode: {e}"))
}

/// Sort object keys recursively; serialize compact UTF-8 JSON (no \\u escapes).
pub fn canonical_json(value: &Value) -> Result<Vec<u8>, String> {
    let sorted = sort_json_keys(value);
    serde_json::to_vec(&sorted).map_err(|e| format!("canonical json: {e}"))
}

fn sort_json_keys(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut btree: BTreeMap<String, Value> = BTreeMap::new();
            for (k, v) in map {
                btree.insert(k.clone(), sort_json_keys(v));
            }
            Value::Object(btree.into_iter().collect::<Map<String, Value>>())
        }
        Value::Array(items) => Value::Array(items.iter().map(sort_json_keys).collect()),
        _ => value.clone(),
    }
}

pub fn derive_cmd_key(pair_secret: &[u8], device_id: &str) -> Result<[u8; 32], String> {
    if pair_secret.len() != SECRET_LEN {
        return Err("pair_secret must be 256 bits".into());
    }
    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), pair_secret);
    let mut okm = [0u8; 32];
    hk.expand(device_id.as_bytes(), &mut okm)
        .map_err(|e| format!("hkdf expand: {e}"))?;
    Ok(okm)
}

pub fn encrypt_cmd(
    cmd: &Value,
    pair_secret: &[u8],
    device_id: &str,
    iv: &[u8],
) -> Result<(String, String, String), String> {
    if iv.len() != IV_LEN {
        return Err("iv must be 12 bytes".into());
    }
    let key = derive_cmd_key(pair_secret, device_id)?;
    let cipher =
        Aes256Gcm::new_from_slice(&key).map_err(|e| format!("aes key: {e}"))?;
    let plaintext = canonical_json(cmd)?;
    let sealed = cipher
        .encrypt(Nonce::from_slice(iv), plaintext.as_ref())
        .map_err(|e| format!("aes-gcm encrypt: {e}"))?;
    if sealed.len() < TAG_LEN {
        return Err("aes-gcm output too short".into());
    }
    let split = sealed.len() - TAG_LEN;
    Ok((
        b64url_encode(iv),
        b64url_encode(&sealed[..split]),
        b64url_encode(&sealed[split..]),
    ))
}

pub fn envelope_sig_message(envelope: &Value) -> Result<Vec<u8>, String> {
    let parts = [
        json_str(envelope.get("v"))?,
        json_str(envelope.get("id"))?,
        json_str(envelope.get("seq"))?,
        json_str(envelope.get("issued_at"))?,
        json_str(envelope.get("device_id"))?,
        json_str(envelope.get("iv"))?,
        json_str(envelope.get("ct"))?,
        json_str(envelope.get("tag"))?,
    ];
    Ok(parts.join("|").into_bytes())
}

pub fn sign_envelope(envelope: &Value, pair_secret: &[u8]) -> Result<String, String> {
    if pair_secret.len() != SECRET_LEN {
        return Err("pair_secret must be 256 bits".into());
    }
    let mut mac = <HmacSha256 as Mac>::new_from_slice(pair_secret)
        .map_err(|e| format!("hmac key: {e}"))?;
    mac.update(&envelope_sig_message(envelope)?);
    Ok(b64url_encode(&mac.finalize().into_bytes()))
}

pub fn result_sig_message(result: &Value) -> Result<Vec<u8>, String> {
    let reason = match result.get("reason") {
        None | Some(Value::Null) => String::new(),
        Some(v) => json_str(Some(v))?,
    };
    let job_ref = match result.get("job_ref") {
        None | Some(Value::Null) => String::new(),
        Some(v) => json_str(Some(v))?,
    };
    let parts = [
        json_str(result.get("id"))?,
        json_str(result.get("status"))?,
        reason,
        job_ref,
        json_str(result.get("at"))?,
    ];
    Ok(parts.join("|").into_bytes())
}

pub fn verify_result_sig(result: &Value, pair_secret: &[u8]) -> bool {
    let Some(sig) = result.get("sig").and_then(|v| v.as_str()) else {
        return false;
    };
    if sig.is_empty() || pair_secret.len() != SECRET_LEN {
        return false;
    }
    let Ok(got) = b64url_decode(sig) else {
        return false;
    };
    let Ok(msg) = result_sig_message(result) else {
        return false;
    };
    let Ok(mut mac) = <HmacSha256 as Mac>::new_from_slice(pair_secret) else {
        return false;
    };
    mac.update(&msg);
    mac.verify_slice(&got).is_ok()
}

pub fn build_envelope(
    cmd: &Value,
    pair_secret: &[u8],
    device_id: &str,
    command_id: &str,
    seq: u64,
    issued_at: &str,
    iv: &[u8],
) -> Result<Value, String> {
    let (iv_b64, ct_b64, tag_b64) = encrypt_cmd(cmd, pair_secret, device_id, iv)?;
    let mut envelope = serde_json::json!({
        "v": 1,
        "id": command_id,
        "seq": seq,
        "issued_at": issued_at,
        "device_id": device_id,
        "iv": iv_b64,
        "ct": ct_b64,
        "tag": tag_b64,
        "sig": "",
    });
    let sig = sign_envelope(&envelope, pair_secret)?;
    envelope
        .as_object_mut()
        .ok_or_else(|| "envelope not object".to_string())?
        .insert("sig".into(), Value::String(sig));
    Ok(envelope)
}

fn json_str(value: Option<&Value>) -> Result<String, String> {
    match value {
        None | Some(Value::Null) => Err("missing envelope field".into()),
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Number(n)) => Ok(n.to_string()),
        Some(Value::Bool(b)) => Ok(b.to_string()),
        _ => Err("unsupported json type in sig field".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: [u8; 32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31,
    ];
    const DEVICE: &str = "dev_7f3a";
    const IV: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

    fn utf8_cmd() -> Value {
        serde_json::json!({
            "type": "spawn",
            "host": "mini",
            "agent": "claude",
            "workdir_id": "w1",
            "prompt": "café 東京 🎉 “hello”",
        })
    }

    #[test]
    fn canonical_json_literal_utf8() {
        let body = canonical_json(&utf8_cmd()).expect("canonical");
        let text = String::from_utf8(body).expect("utf8");
        assert!(!text.contains("\\u"));
        assert!(text.contains('é'));
        assert!(text.contains('東'));
        assert!(text.contains('🎉'));
        assert!(text.contains('“'));
        assert_eq!(
            text,
            r#"{"agent":"claude","host":"mini","prompt":"café 東京 🎉 “hello”","type":"spawn","workdir_id":"w1"}"#
        );
    }

    #[test]
    fn encrypt_vector_matches_hub() {
        let (iv, ct, tag) = encrypt_cmd(&utf8_cmd(), &SECRET, DEVICE, &IV).expect("encrypt");
        assert_eq!(iv, "AAECAwQFBgcICQoL");
        assert_eq!(
            ct,
            "YoT0ALBNI-JDSgaXRNzxnM5_Xs0EHMRKITyc8R-I74L_A7a8c7hNIu6SCEzvq3hc4dY1\
             Pm_D9CfxyCllmn3iVKH2gW_MlzXNR38M7fniNY5TZ14dgZsESVSHd-dLBK__kZCFv14j\
             qnr_Aw"
        );
        assert_eq!(tag, "w0_Nl3c91bCLsyyvehlIyw");
    }

    #[test]
    fn envelope_sig_vector_matches_hub() {
        let (iv, ct, tag) = encrypt_cmd(&utf8_cmd(), &SECRET, DEVICE, &IV).expect("encrypt");
        let envelope = serde_json::json!({
            "v": 1,
            "id": "01J8X1",
            "seq": 1,
            "issued_at": "2026-08-21T19:20:00Z",
            "device_id": DEVICE,
            "iv": iv,
            "ct": ct,
            "tag": tag,
            "sig": "",
        });
        let sig = sign_envelope(&envelope, &SECRET).expect("sign");
        assert_eq!(sig, "ELvd3m7EJhUa-2o_wUW1w9xGYMf7snYBlZEXQMS5_CA");
    }
}
