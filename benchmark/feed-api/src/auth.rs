//! HS256 bearer-token verification.
//!
//! Spec rules implemented here:
//! - only `Authorization: Bearer <jwt>` counts; anything else is `missing bearer token`
//! - only HS256 is accepted; a bad signature, a non-HS256 `alg`, a structurally broken
//!   JWT or a missing/invalid/expired `exp` all map to `invalid or expired token`
//! - `exp` is an RFC 7519 NumericDate: any finite JSON number, integer or
//!   fractional, compared against current Unix time with fractional-second
//!   precision
//! - a correctly signed token whose payload has a `sub` that is not a positive integer
//!   string or a `username` that is not a string maps to `invalid token payload`
//! - every authenticated request verifies the signature: no verification is remembered
//!   across requests

use axum::http::{HeaderMap, header::AUTHORIZATION};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

use crate::error::ApiError;

#[derive(Debug, Clone)]
pub struct Claims {
    pub user_id: i64,
    pub username: String,
}

/// Verifies the `Authorization` header of an authenticated route.
pub fn authenticate(headers: &HeaderMap, secret: &[u8]) -> Result<Claims, ApiError> {
    let value = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or(ApiError::MissingBearerToken)?;
    let token = value
        .strip_prefix("Bearer ")
        .ok_or(ApiError::MissingBearerToken)?;
    verify(token, secret)
}

/// Verifies a compact-serialized HS256 JWT and returns its validated claims.
fn verify(token: &str, secret: &[u8]) -> Result<Claims, ApiError> {
    let invalid = || ApiError::InvalidToken;

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

    // `exp` must be present and a finite number (RFC 7519 §2 NumericDate:
    // "non-integer values can be represented"); the token is only valid
    // strictly before it.
    let exp = claims
        .get("exp")
        .and_then(Value::as_f64)
        .ok_or_else(invalid)?;
    if !exp.is_finite() {
        return Err(invalid());
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    if now >= exp {
        return Err(invalid());
    }

    let payload_error = || ApiError::InvalidTokenPayload;
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
    use hmac::{Hmac, Mac};
    use serde_json::json;
    use sha2::Sha256;

    const SECRET: &[u8] = b"test-secret";

    fn sign(payload: &serde_json::Value, header: &str, secret: &[u8]) -> String {
        let h = B64.encode(header);
        let p = B64.encode(serde_json::to_vec(payload).unwrap());
        let mut mac = Hmac::<Sha256>::new_from_slice(secret).unwrap();
        mac.update(h.as_bytes());
        mac.update(b".");
        mac.update(p.as_bytes());
        let s = B64.encode(mac.finalize().into_bytes());
        format!("{h}.{p}.{s}")
    }

    fn token(payload: &serde_json::Value) -> String {
        sign(payload, r#"{"alg":"HS256","typ":"JWT"}"#, SECRET)
    }

    fn verify_str(t: &str) -> Result<Claims, ApiError> {
        verify(t, SECRET)
    }

    fn claims(sub: &str, username: Option<&str>, exp_offset: i64) -> serde_json::Value {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let mut payload = json!({"sub": sub, "iat": now, "exp": now + exp_offset});
        match username {
            Some(u) => payload["username"] = json!(u),
            None => {
                payload.as_object_mut().unwrap().remove("username");
            }
        }
        payload
    }

    #[test]
    fn accepts_valid_token() {
        let claims = verify_str(&token(&claims("7", Some("user_7"), 3600))).unwrap();
        assert_eq!(claims.user_id, 7);
        assert_eq!(claims.username, "user_7");
    }

    #[test]
    fn rejects_missing_bearer_pieces() {
        assert_eq!(verify_str("abc").unwrap_err(), ApiError::InvalidToken);
        assert_eq!(verify_str("a.b").unwrap_err(), ApiError::InvalidToken);
        assert_eq!(verify_str("a.b.c.d").unwrap_err(), ApiError::InvalidToken);
        assert_eq!(verify_str("").unwrap_err(), ApiError::InvalidToken);
    }

    #[test]
    fn rejects_bad_signature() {
        let good = token(&claims("1", Some("u"), 3600));
        let tampered = format!(
            "{}.not-a-real-signature-at-all-0000",
            &good[..good.rfind('.').unwrap()]
        );
        assert_eq!(verify_str(&tampered).unwrap_err(), ApiError::InvalidToken);

        let other_secret = sign(
            &claims("1", Some("u"), 3600),
            r#"{"alg":"HS256"}"#,
            b"wrong-secret",
        );
        assert_eq!(
            verify_str(&other_secret).unwrap_err(),
            ApiError::InvalidToken
        );
    }

    #[test]
    fn rejects_non_hs256_algorithms() {
        let p = claims("1", Some("u"), 3600);
        let none = format!(
            "{}.{}.",
            B64.encode(br#"{"alg":"none","typ":"JWT"}"#),
            B64.encode(serde_json::to_vec(&p).unwrap())
        );
        assert_eq!(verify_str(&none).unwrap_err(), ApiError::InvalidToken);
        assert_eq!(
            verify_str(&sign(&p, r#"{"alg":"HS512"}"#, SECRET)).unwrap_err(),
            ApiError::InvalidToken
        );
    }

    #[test]
    fn rejects_expired_and_missing_exp() {
        assert_eq!(
            verify_str(&token(&claims("1", Some("u"), -10))).unwrap_err(),
            ApiError::InvalidToken
        );
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        assert_eq!(
            verify_str(&token(&json!({"sub":"1","username":"u","iat":now}))).unwrap_err(),
            ApiError::InvalidToken
        );
        assert_eq!(
            verify_str(&token(&json!({"sub":"1","username":"u","exp":"soon"}))).unwrap_err(),
            ApiError::InvalidToken
        );
    }

    #[test]
    fn accepts_fractional_numeric_dates() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        // RFC 7519 §2: "non-integer values can be represented".
        let fractional = json!({"sub":"1","username":"u","exp": now as f64 + 3600.5});
        assert_eq!(verify_str(&token(&fractional)).unwrap().user_id, 1);
        // A float that happens to be integral is equally valid.
        let integral_float = json!({"sub":"2","username":"u","exp": (now + 3600) as f64});
        assert_eq!(verify_str(&token(&integral_float)).unwrap().user_id, 2);
        // Valid only for a fraction of a second past the next whole second
        // (`now` is floored, so at least 1.5 s remain): the fractional part is
        // what makes this token verifiable — as_i64 would reject it.
        let barely = json!({"sub":"3","username":"u","exp": now as f64 + 2.5});
        assert_eq!(verify_str(&token(&barely)).unwrap().user_id, 3);
    }

    #[test]
    fn rejects_expired_fractional_exp() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        // Half a second in the past cannot become valid by scheduling delay.
        let payload = json!({"sub":"1","username":"u","exp": now as f64 - 0.5});
        assert_eq!(
            verify_str(&token(&payload)).unwrap_err(),
            ApiError::InvalidToken
        );
    }

    #[test]
    fn rejects_non_numeric_exp_types() {
        for exp in [
            Value::Null,
            json!(true),
            json!(false),
            json!(["soon"]),
            json!({"t":1}),
        ] {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            let mut payload = json!({"sub":"1","username":"u","iat":now});
            payload.as_object_mut().unwrap().insert("exp".into(), exp);
            assert_eq!(
                verify_str(&token(&payload)).unwrap_err(),
                ApiError::InvalidToken
            );
        }
    }

    #[test]
    fn classifies_payload_errors() {
        assert_eq!(
            verify_str(&token(&claims("abc", Some("u"), 3600))).unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(&claims("0", Some("u"), 3600))).unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(&claims("-1", Some("u"), 3600))).unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(&claims("1.5", Some("u"), 3600))).unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(
                &json!({"sub":1,"username":"u","exp":99999999999i64})
            ))
            .unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(&claims("1", None, 3600))).unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        assert_eq!(
            verify_str(&token(
                &json!({"sub":"1","username":42,"exp":99999999999i64})
            ))
            .unwrap_err(),
            ApiError::InvalidTokenPayload
        );
        // A correctly signed token with a payload that is not a JSON object is malformed.
        let p = B64.encode(b"not json");
        let mut mac = Hmac::<Sha256>::new_from_slice(SECRET).unwrap();
        mac.update(br#"eyJhbGciOiJIUzI1NiJ9"#);
        mac.update(b".");
        mac.update(p.as_bytes());
        let t = format!(
            "eyJhbGciOiJIUzI1NiJ9.{p}.{}",
            B64.encode(mac.finalize().into_bytes())
        );
        assert_eq!(verify_str(&t).unwrap_err(), ApiError::InvalidToken);
    }

    #[test]
    fn authenticate_requires_bearer_prefix() {
        let mut headers = HeaderMap::new();
        assert_eq!(
            authenticate(&headers, SECRET).unwrap_err(),
            ApiError::MissingBearerToken
        );
        headers.insert(AUTHORIZATION, "Basic abc".parse().unwrap());
        assert_eq!(
            authenticate(&headers, SECRET).unwrap_err(),
            ApiError::MissingBearerToken
        );
        headers.insert(AUTHORIZATION, "Bearer".parse().unwrap());
        assert_eq!(
            authenticate(&headers, SECRET).unwrap_err(),
            ApiError::MissingBearerToken
        );
        headers.insert(
            AUTHORIZATION,
            format!("Bearer {}", token(&claims("3", Some("x"), 60)))
                .parse()
                .unwrap(),
        );
        assert_eq!(authenticate(&headers, SECRET).unwrap().user_id, 3);
    }
}
