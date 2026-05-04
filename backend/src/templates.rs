use serde_json::{Map, Value};

#[derive(Debug, sqlx::FromRow)]
#[allow(dead_code)] // user_id is part of the row contract; routes don't read it but it's queried
pub struct Template {
    pub user_id: String,
    pub name: String,
    pub default_payload: String,
    pub created_at: i64,
    pub updated_at: i64,
}

pub async fn list(pool: &sqlx::SqlitePool, user_id: &str) -> sqlx::Result<Vec<Template>> {
    sqlx::query_as::<_, Template>(
        "SELECT user_id, name, default_payload, created_at, updated_at \
         FROM notification_templates WHERE user_id = ? ORDER BY name ASC",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await
}

pub async fn get(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    name: &str,
) -> sqlx::Result<Option<Template>> {
    sqlx::query_as::<_, Template>(
        "SELECT user_id, name, default_payload, created_at, updated_at \
         FROM notification_templates WHERE user_id = ? AND name = ?",
    )
    .bind(user_id)
    .bind(name)
    .fetch_optional(pool)
    .await
}

pub async fn upsert(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    name: &str,
    default_payload: &Value,
    now_unix: i64,
) -> sqlx::Result<()> {
    let serialized = default_payload.to_string();
    sqlx::query(
        "INSERT INTO notification_templates \
            (user_id, name, default_payload, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?) \
         ON CONFLICT (user_id, name) DO UPDATE SET \
            default_payload = excluded.default_payload, \
            updated_at = excluded.updated_at",
    )
    .bind(user_id)
    .bind(name)
    .bind(&serialized)
    .bind(now_unix)
    .bind(now_unix)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn delete(pool: &sqlx::SqlitePool, user_id: &str, name: &str) -> sqlx::Result<bool> {
    let result = sqlx::query("DELETE FROM notification_templates WHERE user_id = ? AND name = ?")
        .bind(user_id)
        .bind(name)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}

/// Webhook-time merge: look up the template for `(user_id, name)`. If none, return
/// `request_payload` unchanged. If present, merge the template's default_payload
/// with `request_payload`: top-level fields from request override the template;
/// the value MUST end up as a JSON object (never returns null/scalar/array root).
/// Arrays in either layer fully replace (no element-wise merge).
pub async fn merge_with_template(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    name: &str,
    request_payload: Value,
) -> sqlx::Result<Value> {
    let request_obj = match request_payload {
        Value::Object(map) => map,
        _ => Map::new(),
    };

    let template = get(pool, user_id, name).await?;
    let Some(template) = template else {
        return Ok(Value::Object(request_obj));
    };

    let parsed: Value = match serde_json::from_str(&template.default_payload) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(error = %e, "template default_payload is not valid JSON; ignoring");
            return Ok(Value::Object(request_obj));
        }
    };

    let Value::Object(template_obj) = parsed else {
        tracing::warn!("template default_payload is not a JSON object; ignoring");
        return Ok(Value::Object(request_obj));
    };

    let mut merged = template_obj;
    for (k, v) in request_obj {
        merged.insert(k, v);
    }
    Ok(Value::Object(merged))
}
