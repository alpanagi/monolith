export const print = (heap) => (string_idx) => {
    const dataView = new DataView(heap);
    const uint8View = new Uint8Array(heap);
    const length = dataView.getUint32(0, true);

    const text = String.fromCharCode(
        ...uint8View.slice(string_idx + 4, string_idx + 4 + length));
    console.log(text);
}
