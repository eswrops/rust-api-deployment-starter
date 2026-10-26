//! HS256 bearer-token verification shared by future authenticated routes.
//!
//! Semantics (matching the benchmark contract, but framework-free):
//! - `Authorization: Bearer <jwt>` or nothing
//! - HS256 only; bad signature, non-HS256 `alg`, malformed JWT, or missing /
//!   expired `exp` all yield [`AuthError::InvalidToken`]
//! - a correctly signed token whose payload has a non-positive-integer `sub`
//!   or a non-string `username` yields [`AuthError::InvalidPayload`]
//! - every call verifies the signature; nothing is cached across requests

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    MissingBearer,
    InvalidToken,
    InvalidPayload,
}

#[derive(Debug, Clone)]
pub struct Claims {
    pub user_id: i64,
    pub username: String,
}

/// Extracts and verifies the bearer token from an `Authorization` header value.
pub fn authenticate(header: Option<&str>, secret: &[u8]) -> Result<Claims, AuthError> {
    let token = header
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or(AuthError::MissingBearer)?;
    verify(token, secret)
}

/// Verifies a compact-serialized HS256 JWT and returns its validated claims.
pub fn verify(token: &str, secret: &[u8]) -> Result<Claims, AuthError> {
    let invalid = || AuthError::InvalidToken;

    let Some((header64, payload64, signature64)) = split3(token) else {
        return Err(invalid());
    };
    let header = URL_SAFE_NO_PAD.decode(header64).map_err(|_| invalid())?;
    let header: Value = serde_json::from_slice(&header).map_err(|_| invalid())?;
    if header.get("alg").and_then(Value::as_str) != Some("HS256") {
        return Err(invalid());
    }

    let signature = URL_SAFE_NO_PAD.decode(signature64).map_err(|_| invalid())?;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).map_err(|_| invalid())?;
    mac.update(header64.as_bytes());
    mac.update(b".");
    mac.update(payload64.as_bytes());
    mac.verify_slice(&signature).map_err(|_| invalid())?;

    let payload = URL_SAFE_NO_PAD.decode(payload64).map_err(|_| invalid())?;
    let claims: Value = serde_json::from_slice(&payload).map_err(|_| invalid())?;

    // `exp` must be present and numeric; the token is only valid strictly before it.
    let exp = claims
        .get("exp")
        .and_then(Value::as_i64)
        .ok_or_else(invalid)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if now >= exp.max(0) as u64 {
        return Err(invalid());
    }

    let payload_error = || AuthError::InvalidPayload;
    let sub = claims
        .get("sub")
        .and_then(Value::as_str)
        .ok_or_else(payload_error)?;
    let user_id = positive_integer(sub).ok_or_else(payload_error)?;
    let username = claims
        .get("username")
        .and_then(Value::as_str)
        .ok_or_else(payload_error)?
        .to_owned();

    Ok(Claims { user_id, username })
}

fn split3(token: &str) -> Option<(&str, &str, &str)> {
    let mut parts = token.split('.');
    let a = parts.next()?;
    let b = parts.next()?;
    let c = parts.next()?;
    parts.next().is_none().then_some((a, b, c))
}

/// Parses a non-empty all-digits string as a positive integer ("0" is not positive).
fn positive_integer(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse::<i64>().ok().filter(|&n| n > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
    use serde_json::json;

    const SECRET: &[u8] = b"prod-secret";

    fn token(payload: &Value, secret: &[u8]) -> String {
        let h = B64.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let p = B64.encode(serde_json::to_vec(payload).unwrap());
        let mut mac = Hmac::<Sha256>::new_from_slice(secret).unwrap();
        mac.update(h.as_bytes());
        mac.update(b".");
        mac.update(p.as_bytes());
        format!("{h}.{p}.{}", B64.encode(mac.finalize().into_bytes()))
    }

    fn claims(sub: &str, username: Option<&str>, exp_offset: i64) -> Value {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let mut payload = json!({"sub": sub, "iat": now, "exp": now + exp_offset});
        if let Some(u) = username {
            payload["username"] = json!(u);
        } else {
            payload.as_object_mut().unwrap().remove("username");
        }
        payload
    }

    #[test]
    fn accepts_valid_token() {
        let claims = verify(&token(&claims("9", Some("ops"), 60), SECRET), SECRET).unwrap();
        assert_eq!(claims.user_id, 9);
        assert_eq!(claims.username, "ops");
    }

    #[test]
    fn classifies_failures() {
        let good = token(&claims("1", Some("u"), 60), SECRET);
        let tampered = format!("{}.bad", &good[..good.rfind('.').unwrap()]);
        assert_eq!(
            verify(&tampered, SECRET).unwrap_err(),
            AuthError::InvalidToken
        );
        assert_eq!(
            verify(&good, b"other-secret").unwrap_err(),
            AuthError::InvalidToken
        );

        let h = B64.encode(br#"{"alg":"none"}"#);
        let p = B64.encode(serde_json::to_vec(&claims("1", Some("u"), 60)).unwrap());
        assert_eq!(
            verify(&format!("{h}.{p}."), SECRET).unwrap_err(),
            AuthError::InvalidToken
        );
        assert_eq!(
            verify(&token(&claims("1", Some("u"), -1), SECRET), SECRET).unwrap_err(),
            AuthError::InvalidToken
        );
        assert_eq!(
            verify("not-a-jwt", SECRET).unwrap_err(),
            AuthError::InvalidToken
        );

        assert_eq!(
            verify(&token(&claims("abc", Some("u"), 60), SECRET), SECRET).unwrap_err(),
            AuthError::InvalidPayload
        );
        assert_eq!(
            verify(&token(&claims("1", None, 60), SECRET), SECRET).unwrap_err(),
            AuthError::InvalidPayload
        );
    }

    #[test]
    fn authenticate_requires_bearer_prefix() {
        assert_eq!(
            authenticate(None, SECRET).unwrap_err(),
            AuthError::MissingBearer
        );
        assert_eq!(
            authenticate(Some("Basic abc"), SECRET).unwrap_err(),
            AuthError::MissingBearer
        );
        assert_eq!(
            authenticate(Some("Bearer"), SECRET).unwrap_err(),
            AuthError::MissingBearer
        );
        let header = format!("Bearer {}", token(&claims("2", Some("u"), 60), SECRET));
        assert_eq!(authenticate(Some(&header), SECRET).unwrap().user_id, 2);
    }
}
