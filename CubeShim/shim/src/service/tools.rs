// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use containerd_shim::Error;
use std::fs;
use std::path::Path;
use std::result::Result;

pub fn read_address(file: &str) -> Result<String, Error> {
    let pfile = Path::new(file);
    let sk_file = match fs::read_to_string(pfile) {
        Ok(content) => {
            let sk_file = content.strip_prefix("unix://");
            if sk_file.is_none() {
                return Err(Error::InvalidArgument(format!(
                    "read address failed:{}",
                    content
                )));
            }
            sk_file.unwrap().to_string()
        }
        Err(e) => {
            return Err(Error::IoError {
                context: format!("read file[{}] failed", pfile.display()),
                err: e,
            });
        }
    };
    Ok(sk_file)
}
