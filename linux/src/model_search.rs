use crate::model::Model;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Configuration {
    pub pattern: String,
    pub roots: Vec<String>,
    pub options: Vec<SearchOption>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_bytes: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuation: Option<Value>,
}

#[derive(Clone, PartialEq, Serialize)]
pub(super) struct SearchOption {
    name: String,
    value: String,
}

impl SearchOption {
    pub fn new(name: &str, value: impl Into<String>) -> Self {
        Self {
            name: name.to_owned(),
            value: value.into(),
        }
    }
}

#[derive(Serialize)]
pub(super) struct ResultOrder<'a> {
    #[serde(rename = "runID")]
    pub run_id: &'a str,
    pub sort: &'a str,
    pub ascending: bool,
}

#[derive(Serialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum SearchRequest<'a> {
    Arguments {
        #[serde(flatten)]
        configuration: Configuration,
    },
    Start {
        #[serde(flatten)]
        configuration: Configuration,
        quick: bool,
        content_preview: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        date_reference_time: Option<&'a Value>,
    },
    Poll {
        #[serde(rename = "runID")]
        run_id: &'a str,
    },
    Projection {
        #[serde(flatten)]
        order: ResultOrder<'a>,
        mode: &'a str,
        collapsed: Vec<&'a str>,
        collapse_all: bool,
    },
    Page {
        #[serde(flatten)]
        order: ResultOrder<'a>,
        offset: usize,
        limit: usize,
    },
    ExportCurrent {
        #[serde(flatten)]
        order: ResultOrder<'a>,
        format: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        indices: Option<Vec<u64>>,
    },
}

#[derive(Deserialize)]
struct Started {
    #[serde(rename = "runID")]
    run_id: String,
}

#[derive(Deserialize)]
struct Polled {
    events: Vec<Value>,
}

#[derive(Deserialize)]
struct Exported {
    data: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Projection {
    pub rows: Vec<ProjectionRow>,
    pub visible: u64,
    pub arrival_prefix: bool,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(super) enum ProjectionRow {
    Hit {
        index: usize,
    },
    Group {
        key: String,
        title: String,
        count: u64,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ResultPage {
    pub hits: Vec<Value>,
    pub count: u64,
    pub next_offset: u64,
    pub has_more: bool,
}

impl Model {
    pub(super) fn validate_search(&self, configuration: Configuration) -> Result<(), String> {
        self.request::<Value>(&SearchRequest::Arguments { configuration })
            .map(|_| ())
    }

    pub(super) fn start(
        &self,
        configuration: Configuration,
        quick: bool,
        content_preview: bool,
        date_reference_time: Option<&Value>,
    ) -> Result<String, String> {
        self.request::<Started>(&SearchRequest::Start {
            configuration,
            quick,
            content_preview,
            date_reference_time,
        })
        .map(|reply| reply.run_id)
    }

    pub(super) fn poll(&self, run_id: &str) -> Result<Vec<Value>, String> {
        self.request::<Polled>(&SearchRequest::Poll { run_id })
            .map(|reply| reply.events)
    }

    pub(super) fn projection(
        &self,
        order: ResultOrder<'_>,
        mode: &str,
        collapsed: Vec<&str>,
        collapse_all: bool,
    ) -> Result<Projection, String> {
        self.request(&SearchRequest::Projection {
            order,
            mode,
            collapsed,
            collapse_all,
        })
    }

    pub(super) fn page(
        &self,
        order: ResultOrder<'_>,
        offset: usize,
        limit: usize,
    ) -> Result<ResultPage, String> {
        self.request(&SearchRequest::Page {
            order,
            offset,
            limit,
        })
    }

    pub(super) fn export_current(
        &self,
        order: ResultOrder<'_>,
        format: &str,
        indices: Option<Vec<u64>>,
    ) -> Result<String, String> {
        self.request::<Exported>(&SearchRequest::ExportCurrent {
            order,
            format,
            indices,
        })
        .map(|reply| reply.data)
    }
}
