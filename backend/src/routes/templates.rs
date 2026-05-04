use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{AppError, AppResult};
use crate::models;
use crate::templates;
use crate::AppState;

static NAME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._-]{1,64}$").expect("valid template-name regex"));

const DEFAULT_PAYLOAD_MAX_BYTES: usize = 8 * 1024;
const MAX_ACTIONS: usize = 3;
const FORBIDDEN_KEYS: &[&str] = &["delay", "scheduleTimestamp", "id", "identifier"];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PutTemplateRequest {
    pub default_payload: Value,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateResponse {
    pub name: String,
    pub default_payload: Value,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Serialize)]
pub struct ListTemplatesResponse {
    pub templates: Vec<TemplateResponse>,
}

#[tracing::instrument(skip(state))]
pub async fn list_templates(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> AppResult<Json<ListTemplatesResponse>> {
    let rows = templates::list(&state.db, &user_id).await?;

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let parsed: Value = serde_json::from_str(&row.default_payload).unwrap_or(Value::Null);
        out.push(TemplateResponse {
            name: row.name,
            default_payload: parsed,
            created_at: row.created_at,
            updated_at: row.updated_at,
        });
    }

    tracing::info!(
        user_id_prefix = %short_id(&user_id),
        count = out.len(),
        "templates listed"
    );

    Ok(Json(ListTemplatesResponse { templates: out }))
}

#[tracing::instrument(skip(state))]
pub async fn get_template(
    State(state): State<AppState>,
    Path((user_id, name)): Path<(String, String)>,
) -> AppResult<Json<TemplateResponse>> {
    validate_name(&name)?;

    let row = templates::get(&state.db, &user_id, &name)
        .await?
        .ok_or(AppError::NotFound)?;

    let parsed: Value = serde_json::from_str(&row.default_payload).unwrap_or(Value::Null);

    tracing::info!(
        user_id_prefix = %short_id(&user_id),
        name = %name,
        "template fetched"
    );

    Ok(Json(TemplateResponse {
        name: row.name,
        default_payload: parsed,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }))
}

#[tracing::instrument(skip(state, payload))]
pub async fn put_template(
    State(state): State<AppState>,
    Path((user_id, name)): Path<(String, String)>,
    Json(payload): Json<PutTemplateRequest>,
) -> AppResult<Json<TemplateResponse>> {
    validate_name(&name)?;

    let obj = match &payload.default_payload {
        Value::Object(m) => m,
        _ => {
            return Err(AppError::BadRequest(
                "defaultPayload must be a JSON object".into(),
            ));
        }
    };

    validate_default_payload(obj)?;

    let serialized = payload.default_payload.to_string();
    if serialized.len() > DEFAULT_PAYLOAD_MAX_BYTES {
        return Err(AppError::PayloadTooLarge);
    }

    let now = models::now_unix();
    templates::upsert(&state.db, &user_id, &name, &payload.default_payload, now).await?;

    let row = templates::get(&state.db, &user_id, &name)
        .await?
        .ok_or(AppError::NotFound)?;
    let parsed: Value = serde_json::from_str(&row.default_payload).unwrap_or(Value::Null);

    tracing::info!(
        user_id_prefix = %short_id(&user_id),
        name = %name,
        "template stored"
    );

    Ok(Json(TemplateResponse {
        name: row.name,
        default_payload: parsed,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }))
}

#[tracing::instrument(skip(state))]
pub async fn delete_template(
    State(state): State<AppState>,
    Path((user_id, name)): Path<(String, String)>,
) -> AppResult<StatusCode> {
    validate_name(&name)?;

    let removed = templates::delete(&state.db, &user_id, &name).await?;
    if !removed {
        return Err(AppError::NotFound);
    }

    tracing::info!(
        user_id_prefix = %short_id(&user_id),
        name = %name,
        "template deleted"
    );

    Ok(StatusCode::NO_CONTENT)
}

fn validate_name(name: &str) -> AppResult<()> {
    if !NAME_RE.is_match(name) {
        return Err(AppError::BadRequest("invalid template name".into()));
    }
    Ok(())
}

fn validate_default_payload(obj: &Map<String, Value>) -> AppResult<()> {
    for forbidden in FORBIDDEN_KEYS {
        if obj.contains_key(*forbidden) {
            return Err(AppError::BadRequest(format!(
                "defaultPayload must not contain `{forbidden}`"
            )));
        }
    }

    if let Some(actions) = obj.get("actions") {
        let arr = actions.as_array().ok_or_else(|| {
            AppError::BadRequest("defaultPayload.actions must be an array".into())
        })?;
        if arr.len() > MAX_ACTIONS {
            return Err(AppError::BadRequest(format!(
                "defaultPayload.actions has {} entries; max is {MAX_ACTIONS}",
                arr.len()
            )));
        }
    }

    Ok(())
}

fn short_id(id: &str) -> &str {
    let end = id.char_indices().nth(8).map(|(i, _)| i).unwrap_or(id.len());
    &id[..end]
}
