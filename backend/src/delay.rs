//! Pushcut "1h 5m 10s" delay-string parser (ADR-0015).
//!
//! Wraps `humantime::parse_duration` with the contract specific to ADR-0015:
//! whitespace-separated components in any order, suffixes `d`/`h`/`m`/`s`,
//! result must be a strictly positive whole number of seconds, no overflow.

/// Parse a Pushcut-style delay string like `"1h 5m 10s"` into a positive
/// number of seconds. Accepts components in any order separated by
/// whitespace; supports suffixes `d`, `h`, `m`, `s`. Returns `Err` with a
/// short human-readable reason on parse failure or zero/negative result.
pub fn parse_delay_seconds(input: &str) -> Result<i64, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("delay is empty".to_string());
    }

    let duration = humantime::parse_duration(trimmed).map_err(|e| format!("invalid delay: {e}"))?;

    let secs = duration.as_secs();
    if secs == 0 {
        return Err("delay must be greater than zero".to_string());
    }
    if secs > i64::MAX as u64 {
        return Err("delay overflow".to_string());
    }

    Ok(secs as i64)
}
