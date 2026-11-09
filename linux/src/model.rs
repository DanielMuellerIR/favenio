use libloading::Library;
use serde_json::Value;
use std::mem::ManuallyDrop;
use std::{
    ffi::{c_char, CStr},
    path::Path,
};

type Request = unsafe extern "C" fn(*const u8, usize) -> *mut c_char;
type Release = unsafe extern "C" fn(*mut c_char);

pub struct Model {
    _library: ManuallyDrop<Library>,
    request: Request,
    release: Release,
}
impl Model {
    pub fn load(directory: &Path) -> Result<Self, String> {
        // Die Bibliothek gehört zur gepinnten Version, niemals zur aktuellen Arbeitsmappe.
        unsafe {
            let library =
                Library::new(directory.join("libfavenio-shared.so")).map_err(|e| e.to_string())?;
            let request = *library
                .get::<Request>(b"favenio_model\0")
                .map_err(|e| e.to_string())?;
            let release = *library
                .get::<Release>(b"favenio_model_free\0")
                .map_err(|e| e.to_string())?;
            Ok(Self {
                _library: ManuallyDrop::new(library),
                request,
                release,
            })
        }
    }
    pub fn call(&self, value: Value) -> Result<Value, String> {
        let input = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
        if input.len() > 1_048_576 {
            return Err("Auftrag überschreitet 1 MiB.".into());
        }
        unsafe {
            let pointer = (self.request)(input.as_ptr(), input.len());
            if pointer.is_null() {
                return Err("Gemeinsamer Anwendungskern hat den Auftrag abgewiesen.".into());
            }
            let result = serde_json::from_slice::<Value>(CStr::from_ptr(pointer).to_bytes())
                .map_err(|e| e.to_string());
            (self.release)(pointer);
            let response = result?;
            if response["ok"] != true {
                return Err(response["error"]
                    .as_str()
                    .unwrap_or("Ungültige Antwort.")
                    .into());
            }
            Ok(response)
        }
    }
}
