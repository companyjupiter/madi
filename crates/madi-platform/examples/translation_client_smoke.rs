//! Public-text probe through the native caption client and shared DNA broker.
use madi_core::{
    dna::Priority,
    transcript::Uuid,
    translation::{
        Kind,
        client::{Configuration, Effect, Translation},
    },
};
use madi_platform::{
    dna_broker::{DnaBroker, Event, Launch, Request},
    translation_client::TranslationClient,
};
use serde_json::json;
use std::{collections::BTreeMap, io, path::PathBuf, time::Duration};

async fn next(
    b: &mut DnaBroker,
    c: &mut TranslationClient,
    events: &mut Vec<Event>,
) -> io::Result<Vec<Effect>> {
    let event = tokio::time::timeout(Duration::from_secs(180), b.next())
        .await
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::other("broker stream closed"))?;
    if let Event::Fault { operation, message } = &event {
        return Err(io::Error::other(format!("{operation}: {message}")));
    }
    let update = c.handle(b, &event).await;
    if let Some(fault) = update.fault {
        return Err(io::Error::other(fault));
    }
    events.push(event);
    Ok(update.events)
}
async fn turn(
    b: &mut DnaBroker,
    c: &mut TranslationClient,
    events: &mut Vec<Event>,
    source: &str,
    kind: Kind,
    forced: BTreeMap<String, String>,
) -> io::Result<Translation> {
    let id = Uuid::new_v4();
    let (accepted, update) = c
        .translate(b, source, &["English".into()], id, kind, &forced)
        .await;
    assert!(accepted && update.fault.is_none());
    loop {
        for event in next(b, c, events).await? {
            if let Effect::Result(t) = event
                && t.id == id
            {
                return Ok(t);
            }
        }
    }
}
#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err(io::Error::other(
            "usage: translation_client_smoke ENGINE MODEL",
        ));
    }
    let engine = PathBuf::from(&args[0]);
    let model = PathBuf::from(&args[1]);
    let mut b = DnaBroker::new()?;
    let mut c = TranslationClient::attach(
        &b,
        Launch::new(&engine, &model),
        Configuration {
            priority_language: Some("English".into()),
            ..Configuration::default()
        },
    )
    .await?;
    let background = b.attach(Launch::new(&engine, &model)).await?;
    let mut events = Vec::new();
    let mut results = Vec::new();
    // Queue before READY: the owner must register the native prefix first.
    let first = turn(
        &mut b,
        &mut c,
        &mut events,
        "안녕하세요.",
        Kind::Committed,
        BTreeMap::new(),
    )
    .await?;
    let forced = first.text.clone();
    results.push(first);
    results.push(
        turn(
            &mut b,
            &mut c,
            &mut events,
            "오늘 날씨가 좋습니다.",
            Kind::Committed,
            BTreeMap::new(),
        )
        .await?,
    );
    results.push(
        turn(
            &mut b,
            &mut c,
            &mut events,
            "안녕하세요. 반갑습니다.",
            Kind::Interim,
            BTreeMap::from([("English".into(), forced)]),
        )
        .await?,
    );
    assert!(
        results
            .iter()
            .all(|r| !r.text.is_empty() && !r.text.contains("%%TRN") && !r.text.contains("%%PFX"))
    );
    assert_eq!(c.depth(), 0);
    let request = b
        .submit(
            background,
            Request::turn("Reply with exactly Alpha."),
            Priority::PostSession,
        )
        .await?;
    let background_text = loop {
        next(&mut b, &mut c, &mut events).await?;
        if let Some(Event::Completed {
            request: id,
            text: Some(text),
            ..
        }) = events.last()
            && *id == request
        {
            break text.clone();
        }
    };
    assert!(!background_text.is_empty());
    c.stop(&b).await?;
    b.detach(background).await?;
    while !events.iter().any(|e| matches!(e, Event::Stopped { .. })) {
        next(&mut b, &mut c, &mut events).await?;
    }
    b.shutdown();
    b.wait().await?;
    let starts = events
        .iter()
        .filter(|e| matches!(e, Event::Started { .. }))
        .count();
    let stops = events
        .iter()
        .filter(|e| matches!(e, Event::Stopped { .. }))
        .count();
    assert_eq!((starts, stops), (1, 1));
    println!("{}",serde_json::to_string_pretty(&json!({"status":"PASS","scope":"Public-text native caption client, real model, shared broker; no product UI or quality acceptance","engine":engine,"model":model,"startedProcesses":starts,"reapedProcesses":stops,"clients":2,"depth":c.depth(),"runaways":c.runaway_truncations(),"translations":results.iter().map(|r|json!({"source":r.source,"target":r.language,"text":r.text})).collect::<Vec<_>>(),"background":background_text,"completions":events.iter().filter(|e|matches!(e,Event::Completed{..})).count()})).unwrap());
    Ok(())
}
