use madi_platform::session_archive::SessionArchiveWriter;
use serde::Deserialize;
use serde_json::json;
use std::{collections::BTreeMap, fs, io::Read, path::Path};
#[derive(Deserialize)]
struct Step {
    op: String,
    folder: Option<String>,
    base: Option<String>,
    text: Option<String>,
}
#[derive(Deserialize)]
struct Case {
    steps: Vec<Step>,
}
fn tree(root: &Path, folder: &Path, output: &mut BTreeMap<String, String>) {
    for item in fs::read_dir(folder).unwrap() {
        let path = item.unwrap().path();
        let name = path
            .strip_prefix(root)
            .unwrap()
            .to_str()
            .unwrap()
            .replace('\\', "/");
        if path.is_dir() {
            output.insert(name, "directory".into());
            tree(root, &path, output);
        } else {
            output.insert(
                name,
                fs::read(path)
                    .unwrap()
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect(),
            );
        }
    }
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results:Vec<_>=cases.into_iter().map(|case| {
        let root=tempfile::tempdir().unwrap(); let mut writer=SessionArchiveWriter::default();
        case.steps.iter().map(|step| {
            let folder=root.path().join(step.folder.as_deref().unwrap_or(""));
            let base=step.base.as_deref().unwrap_or("meeting"); let text=step.text.as_deref().unwrap_or("");
            let success=match step.op.as_str() {
                "save"=>writer.save_transcript(text,&folder,base), "summary"=>writer.save_summary(text),
                "rename"=>writer.rename(base,&folder), "reset"=>{writer.reset();true},
                "file"=>{fs::create_dir_all(folder.parent().unwrap()).unwrap(); fs::write(&folder,text).unwrap();true},
                "mkdir"=>{fs::create_dir_all(&folder).unwrap();true},
                "remove"=>{if folder.is_dir(){fs::remove_dir_all(&folder).unwrap()}else{fs::remove_file(&folder).unwrap()};true},
                _=>panic!("unknown writer operation")
            };
            let mut files=BTreeMap::new(); tree(root.path(),root.path(),&mut files);
            json!({"success":success,"error":writer.last_error().is_some(),"pointer":writer.transcript().map(|p|p.strip_prefix(root.path()).unwrap().to_str().unwrap().replace('\\',"/")),"files":files})
        }).collect::<Vec<_>>()
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
