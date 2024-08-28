export const generatePrelude = () =>
    [
        `; Prelude`,
        `declare i64 @fwrite(ptr noundef, i64 noundef, i64 noundef, ptr noundef)`,
        `@stdout = external global ptr, align 8`,
        `@new_line = internal constant [1 x i8] c"\\0A"`,
        ``,
        `define void @print(ptr %string, i64 %length) {`,
        `  %1 = load ptr, ptr @stdout, align 8`,
        `  %2 = call i64 @fwrite(ptr %string, i64 1, i64 %length, ptr %1)`,
        `  %3 = call i64 @fwrite(ptr @new_line, i64 1, i64 1, ptr %1)`,
        `  ret void`,
        `}`,
        `\n`,
    ].join("\n")
