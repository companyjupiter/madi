//! Public-text native DNA probe. No microphone, user transcript or renderer.
use madi_core::dna::Priority;
use madi_platform::{
    dna_broker::{ClientId, DnaBroker, Event, Launch, Request, RequestId},
    model_assets,
};
use serde_json::json;
use std::{collections::BTreeSet, io, path::PathBuf, time::Duration};

async fn until(
    broker: &mut DnaBroker,
    events: &mut Vec<Event>,
    predicate: impl Fn(&Event) -> bool,
) -> io::Result<()> {
    tokio::time::timeout(Duration::from_secs(180), async {
        loop {
            let event = broker
                .next()
                .await
                .ok_or_else(|| io::Error::other("DNA stream closed"))?;
            if let Event::Fault { operation, message } = &event {
                return Err(io::Error::other(format!("{operation}: {message}")));
            }
            let matched = predicate(&event);
            events.push(event);
            if matched {
                return Ok(());
            }
        }
    })
    .await
    .map_err(io::Error::other)?
}

async fn turn(
    broker: &mut DnaBroker,
    events: &mut Vec<Event>,
    client: ClientId,
    request: Request,
    priority: Priority,
) -> io::Result<(RequestId, String)> {
    let id = broker.submit(client, request, priority).await?;
    until(
        broker,
        events,
        |e| matches!(e,Event::Completed {request,..} if *request==id),
    )
    .await?;
    let Some(Event::Completed {
        text: Some(text), ..
    }) = events.last()
    else {
        return Err(io::Error::other("DNA request failed or returned no text"));
    };
    Ok((id, text.clone()))
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err(io::Error::other("usage: dna_broker_smoke ENGINE MODEL"));
    }
    let engine = PathBuf::from(&args[0]);
    let model = PathBuf::from(&args[1]);
    let before = std::fs::metadata(&model)?;
    let engine_hash = model_assets::sha256(&engine)?;
    let model_hash = model_assets::sha256(&model)?;
    let mut broker = DnaBroker::new()?;
    let mut events = Vec::new();
    let launch = Launch::new(&engine, &model);
    let caption = broker.attach(launch.clone()).await?;
    until(
        &mut broker,
        &mut events,
        |e| matches!(e,Event::Ready {client,..} if *client==caption),
    )
    .await?;
    let capabilities: BTreeSet<_> = events
        .iter()
        .filter_map(|e| match e {
            Event::Ready { capabilities, .. } => Some(capabilities),
            _ => None,
        })
        .flatten()
        .cloned()
        .collect();
    assert!(capabilities.contains("pfxcache") && capabilities.contains("fp"));
    let background = broker.attach(launch).await?;
    until(
        &mut broker,
        &mut events,
        |e| matches!(e,Event::Ready {client,..} if *client==background),
    )
    .await?;
    let (_,prefix)=turn(&mut broker,&mut events,caption,Request::Prefix {slot:1,text:"Translate the following into English. Reply with only the translation in English, no notes. Example — ".into()},Priority::CommittedCaption).await?;
    assert_eq!(prefix, "PFX_OK");
    let (_, translation) = turn(
        &mut broker,
        &mut events,
        caption,
        Request::turn("%%TRN 1 Hello => Hello . 안녕하세요. => %%MAX 64"),
        Priority::CommittedCaption,
    )
    .await?;
    let (_, forced) = turn(
        &mut broker,
        &mut events,
        caption,
        Request::turn(
            "%%TRN 1 Hello => Hello . 안녕하세요. 만나서 반갑습니다. => %%MAX 64 %%FP Hello",
        ),
        Priority::InterimCaption,
    )
    .await?;
    assert!(forced.starts_with("Hello"));
    broker.detach(caption).await?;
    let (_,answer)=turn(&mut broker,&mut events,background,Request::Turn {prompt:"Return two short lines: the word Alpha on the first line and the word Beta on the second line. %%MAX 64".into(),preserve_newlines:true},Priority::PostSession).await?;
    broker.detach(background).await?;
    broker.shutdown();
    broker.wait().await?;
    while let Some(event) = broker.next().await {
        events.push(event);
    }
    let starts = events
        .iter()
        .filter(|e| matches!(e, Event::Started { .. }))
        .count();
    let stops = events
        .iter()
        .filter(|e| matches!(e, Event::Stopped { .. }))
        .count();
    assert_eq!((starts, stops), (1, 1));
    assert!(!events.iter().any(|e| matches!(e, Event::Fault { .. })));
    let after = std::fs::metadata(&model)?;
    assert_eq!(
        (before.len(), before.modified()?),
        (after.len(), after.modified()?)
    );
    assert_eq!(engine_hash, model_assets::sha256(&engine)?);
    assert_eq!(model_hash, model_assets::sha256(&model)?);
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "status":"passed","scope":"Shared native DNA broker with public text, not product translation or UI acceptance",
            "engine":engine.file_name().unwrap().to_string_lossy(),"engineSHA256":engine_hash,
            "model":model.file_name().unwrap().to_string_lossy(),"modelBytes":before.len(),"modelSHA256":model_hash,
            "inputModelUnchanged":true,"capabilities":capabilities,"processStarts":starts,"reapedStops":stops,
            "clients":2,"prefixReady":prefix,"translation":translation,"forcedTranslation":forced,"backgroundAnswer":answer,
            "partialEvents":events.iter().filter(|e|matches!(e,Event::Partial {..})).count(),
            "completions":events.iter().filter(|e|matches!(e,Event::Completed {..})).count(),
            "finalCaptionBusy":events.iter().rev().find_map(|e|match e {Event::CaptionBusy(value)=>Some(*value),_=>None}),
            "uiAcceptance":"NOT_RUN"
        }))?
    );
    Ok(())
}
