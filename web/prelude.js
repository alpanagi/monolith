export const print = (heap) => (fatPointer) => {
    const dataView = new DataView(heap);
    const uint8View = new Uint8Array(heap);

    const idx = dataView.getUint32(fatPointer, true);
    const length = dataView.getUint32(fatPointer + 4, true);

    const text = String.fromCharCode(
        ...uint8View.slice(idx, idx + length));
    console.log(text);
}
