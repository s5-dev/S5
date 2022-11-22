use super::*;
// Section: wire functions

#[wasm_bindgen]
pub fn wire_hash_blake3_file(port_: MessagePort, path: String) {
    wire_hash_blake3_file_impl(port_, path)
}

#[wasm_bindgen]
pub fn wire_hash_blake3(port_: MessagePort, input: Box<[u8]>) {
    wire_hash_blake3_impl(port_, input)
}

#[wasm_bindgen]
pub fn wire_verify_integrity(
    port_: MessagePort,
    chunk_bytes: Box<[u8]>,
    offset: u64,
    bao_outboard_bytes: Box<[u8]>,
    blake3_hash: Box<[u8]>,
) {
    wire_verify_integrity_impl(port_, chunk_bytes, offset, bao_outboard_bytes, blake3_hash)
}

#[wasm_bindgen]
pub fn wire_hash_bao_file(port_: MessagePort, path: String) {
    wire_hash_bao_file_impl(port_, path)
}

#[wasm_bindgen]
pub fn wire_hash_bao_memory(port_: MessagePort, bytes: Box<[u8]>) {
    wire_hash_bao_memory_impl(port_, bytes)
}

// Section: allocate functions

// Section: impl Wire2Api

impl Wire2Api<String> for String {
    fn wire2api(self) -> String {
        self
    }
}

impl Wire2Api<Vec<u8>> for Box<[u8]> {
    fn wire2api(self) -> Vec<u8> {
        self.into_vec()
    }
}
// Section: impl Wire2Api for JsValue

impl Wire2Api<String> for JsValue {
    fn wire2api(self) -> String {
        self.as_string().expect("non-UTF-8 string, or not a string")
    }
}
impl Wire2Api<u64> for JsValue {
    fn wire2api(self) -> u64 {
        ::std::convert::TryInto::try_into(self.dyn_into::<js_sys::BigInt>().unwrap()).unwrap()
    }
}
impl Wire2Api<u8> for JsValue {
    fn wire2api(self) -> u8 {
        self.unchecked_into_f64() as _
    }
}
impl Wire2Api<Vec<u8>> for JsValue {
    fn wire2api(self) -> Vec<u8> {
        self.unchecked_into::<js_sys::Uint8Array>().to_vec().into()
    }
}
