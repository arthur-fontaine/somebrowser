//! C API over Brave's adblock-rust, for the AdBlock feature (Swift). Strings in and out are UTF-8;
//! every returned pointer is freed by the matching `adb_*_free`.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

fn text<'a>(s: *const c_char) -> &'a str {
    if s.is_null() {
        return "";
    }
    unsafe { CStr::from_ptr(s) }.to_str().unwrap_or("")
}

fn out(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(ptr::null_mut())
}

/// Compiles filter lists (concatenated list text). `trusted_lists` may use trusted scriptlets (`trusted-*`, uBlock
/// Origin's own lists); may be null.
#[no_mangle]
pub extern "C" fn adb_engine_new(lists: *const c_char, trusted_lists: *const c_char) -> *mut Engine {
    let mut set = FilterSet::new(false);
    set.add_filter_list(text(lists).to_string(), ParseOptions::default());
    if !trusted_lists.is_null() {
        let trusted = ParseOptions { permissions: adblock::resources::PermissionMask::from_bits(1), ..ParseOptions::default() };
        set.add_filter_list(text(trusted_lists).to_string(), trusted);
    }
    Box::into_raw(Box::new(Engine::new_with_filter_set(set)))
}

/// Loads redirect and scriptlet resources (Brave's `resources.json`: a JSON array of adblock-rust `Resource`s),
/// replacing any loaded before. Resources aren't part of the serialized engine. Returns how many were loaded, or -1 if
/// the JSON doesn't parse. Call before the engine is shared between threads.
#[no_mangle]
pub extern "C" fn adb_engine_use_resources(engine: *mut Engine, json: *const c_char) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return -1 };
    match serde_json::from_str::<Vec<adblock::resources::Resource>>(text(json)) {
        Ok(resources) => {
            let count = resources.len() as i32;
            engine.use_resources(resources);
            count
        }
        Err(_) => -1,
    }
}

/// Restores an engine from `adb_engine_serialize` output (fast startup). Null when the data is stale.
#[no_mangle]
pub extern "C" fn adb_engine_deserialize(data: *const u8, len: usize) -> *mut Engine {
    if data.is_null() {
        return ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let mut engine = Engine::default();
    match engine.deserialize(bytes) {
        Ok(()) => Box::into_raw(Box::new(engine)),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn adb_engine_serialize(engine: *const Engine, len: *mut usize) -> *mut u8 {
    let engine = unsafe { &*engine };
    let mut bytes = engine.serialize().into_boxed_slice();
    unsafe { *len = bytes.len() };
    let p = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    p
}

#[no_mangle]
pub extern "C" fn adb_bytes_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::slice::from_raw_parts_mut(data, len)) });
    }
}

#[no_mangle]
pub extern "C" fn adb_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[no_mangle]
pub extern "C" fn adb_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Matches a request. Returns 1 to block, 0 to allow. `redirect` (a data: URL body to serve instead) and
/// `rewritten` (the URL without tracking parameters) are set when the lists ask for them.
#[no_mangle]
pub extern "C" fn adb_check(
    engine: *const Engine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
    redirect: *mut *mut c_char,
    rewritten: *mut *mut c_char,
) -> i32 {
    let engine = unsafe { &*engine };
    let Ok(request) = Request::new(text(url), text(source_url), text(request_type), "GET") else {
        return 0;
    };
    let result = engine.check_network_request(&request);
    unsafe {
        if !redirect.is_null() {
            *redirect = result.redirect.clone().map(out).unwrap_or(ptr::null_mut());
        }
        if !rewritten.is_null() {
            *rewritten = result.rewritten_url.clone().map(out).unwrap_or(ptr::null_mut());
        }
    }
    result.should_block() as i32
}

/// Cosmetic resources for a page: JSON `{hide_selectors, exceptions, injected_script, generichide}`.
#[no_mangle]
pub extern "C" fn adb_cosmetic(engine: *const Engine, url: *const c_char) -> *mut c_char {
    let engine = unsafe { &*engine };
    let r = engine.url_cosmetic_resources(text(url));
    out(serde_json::json!({
        "hide_selectors": r.hide_selectors,
        "exceptions": r.exceptions,
        "injected_script": r.injected_script,
        "generichide": r.generichide,
    })
    .to_string())
}

/// Generic hide selectors for the classes and ids seen on a page (JSON arrays in, JSON array out).
#[no_mangle]
pub extern "C" fn adb_hidden_selectors(
    engine: *const Engine,
    classes: *const c_char,
    ids: *const c_char,
    exceptions: *const c_char,
) -> *mut c_char {
    let engine = unsafe { &*engine };
    let parse = |s| serde_json::from_str::<Vec<String>>(text(s)).unwrap_or_default();
    let exceptions: HashSet<String> = parse(exceptions).into_iter().collect();
    out(serde_json::to_string(&engine.hidden_class_id_selectors(parse(classes), parse(ids), &exceptions)).unwrap_or_default())
}

/// Converts lists to Apple content-blocker JSON (WebKit engine).
#[no_mangle]
pub extern "C" fn adb_content_blocking(lists: *const c_char) -> *mut c_char {
    let mut set = FilterSet::new(true);
    set.add_filter_list(text(lists).to_string(), ParseOptions::default());
    match set.into_content_blocking() {
        Ok((rules, _)) => out(serde_json::to_string(&rules).unwrap_or_else(|_| "[]".into())),
        Err(()) => out("[]".into()),
    }
}
