mod types;
pub mod utils;
use crate::types::ResultVec;

pub fn pipe(fns: Vec<Box<dyn Fn(String) -> ResultVec>>) -> ResultVec {
    fns.iter().fold(Ok(vec!["".to_string()]), |in_acc, f| {
        in_acc?
            .iter()
            .fold(Ok(Vec::new()), |out_acc, x| match out_acc {
                Ok(val) => match f(x.clone()) {
                    Ok(x) => {
                        let mut out = val.clone();
                        out.extend(x);
                        Ok(out)
                    }
                    Err(err) => Err(err),
                },
                Err(err) => Err(err),
            })
    })
}
