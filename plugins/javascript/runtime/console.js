let bufferedText = "";

export function mn_console_write(text) {
    let startIndex = 0;
    while (true) {
        const newlineIndex = text.indexOf("\n", startIndex);
        if (newlineIndex === -1) {
            bufferedText += text.slice(startIndex);
            return;
        }
        bufferedText += text.slice(startIndex, newlineIndex);
        console.log(bufferedText);
        bufferedText = "";
        startIndex = newlineIndex + 1;
    }
}
