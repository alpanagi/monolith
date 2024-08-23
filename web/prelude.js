export const print = (heap) => (memoryIdx, length) => {
  const uint8View = new Uint8Array(heap);

  const text = String.fromCharCode(
    ...uint8View.slice(memoryIdx, memoryIdx + length),
  );
  console.log(text);
};
