use crate::types::ResultVec;
use std::fs::{read_dir, DirEntry};

pub fn echo(text: String) -> Box<dyn Fn(String) -> ResultVec> {
    Box::new(move |_| Ok(vec![text.clone()]))
}

pub fn ls_wd() -> Box<dyn Fn(String) -> ResultVec> {
    let dirs = read_dir("./").unwrap();
    let paths: Vec<DirEntry> = dirs.map(|x| x.unwrap()).collect();
    let names: Vec<String> = paths
        .iter()
        .map(|x| x.path().to_str().unwrap().to_string())
        .collect();
    Box::new(move |_| Ok(names.clone()))
}
