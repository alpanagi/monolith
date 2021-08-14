use crate::types::ResultVec;

pub fn echo(text: String) -> impl Fn(String) -> ResultVec {
    move |_| Ok(vec![text.clone()])
}
