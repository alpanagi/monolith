use std::iter::once;
use std::result::Result;

pub fn echo<S: Into<String>>(input: S) -> Result<impl Iterator<Item = String>, String> {
    Ok(once(input.into()))
}
