use crate::frb_generated::StreamSink;
use anyhow::{Context, Result};
use futures::StreamExt;
use iroh::{discovery::pkarr::PkarrPublisher, Endpoint, SecretKey};
use iroh_blobs::api::blobs::{AddPathOptions, ImportMode};
use iroh_blobs::BlobFormat;
use iroh_blobs::protocol::GetRequest;
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::ticket::BlobTicket;
use iroh_blobs::BlobsProtocol;
use std::path::PathBuf;
use std::str::FromStr;
use tokio::io::AsyncReadExt;

fn get_secret() -> SecretKey {
    SecretKey::generate(&mut rand::rng())
}

pub async fn start_send(file_path: String, data_dir: String, sink: StreamSink<String>) -> Result<()> {
    let path = PathBuf::from(&file_path);
    if !path.exists() {
        sink.add("Error: File does not exist".to_string()).ok();
        return Ok(())
    }

    sink.add("[V17-FORCE-REBUILD] Initializing...".to_string()).ok();

    let data_path = PathBuf::from(&data_dir).join("sendme_store_send");
    tokio::fs::create_dir_all(&data_path).await?;
    let store = FsStore::load(&data_path).await?;

    sink.add("Importing...".to_string()).ok();
    
    let import = store.add_path_with_opts(AddPathOptions {
        path: path.clone(),
        mode: ImportMode::TryReference,
        format: BlobFormat::Raw,
    });
    
    let mut stream = import.stream().await;
    let mut hash = None;
    while let Some(item) = stream.next().await {
        if let iroh_blobs::api::blobs::AddProgressItem::Done(t) = item {
             hash = Some(t.hash());
        }
    }
    let hash = hash.context("Import failed")?;

    let secret_key = get_secret();
    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .discovery(PkarrPublisher::n0_dns())
        .alpns(vec![iroh_blobs::protocol::ALPN.to_vec()])
        .bind().await?;
        
    let blobs = BlobsProtocol::new(&store, None); 
    let router = iroh::protocol::Router::builder(endpoint)
        .accept(iroh_blobs::ALPN, blobs.clone())
        .spawn();

    let ep = router.endpoint();
    ep.online().await;

    let ticket = BlobTicket::new(ep.addr(), hash, BlobFormat::Raw);
    sink.add("TICKET:".to_string() + &ticket.to_string()).ok();
    sink.add("Ready!".to_string()).ok();

    futures::future::pending::<()>().await;
    router.shutdown().await?;
    Ok(())
}

pub async fn receive_file(ticket_str: String, data_dir: String, download_dir: String, sink: StreamSink<String>) -> Result<()> {
    let ticket = BlobTicket::from_str(&ticket_str).context("Invalid ticket")?;
    sink.add("[V17-FORCE-REBUILD] Initializing...".to_string()).ok();
    
    let data_path = PathBuf::from(&data_dir).join("sendme_store_recv");
    tokio::fs::create_dir_all(&data_path).await?;
    let store = FsStore::load(&data_path).await?;

    let secret_key = get_secret();
    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .discovery(PkarrPublisher::n0_dns())
        .alpns(vec![iroh_blobs::protocol::ALPN.to_vec()])
        .bind().await?;
    
    endpoint.online().await;
    sink.add("Connecting...".to_string()).ok();
    let connection = endpoint.connect(ticket.addr().clone(), iroh_blobs::protocol::ALPN).await?;
    
    sink.add("Downloading...".to_string()).ok();
    let hash = ticket.hash();
    
    let get = store.remote().execute_get(connection, GetRequest::blob(hash));
    let mut stream = get.stream();
    while let Some(item) = stream.next().await {
         if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
             sink.add("Error: ".to_string() + &e.to_string()).ok();
             return Err(anyhow::anyhow!("Download failed"));
         }
    }

    sink.add("Analyzing file header...".to_string()).ok();
    
    let mut reader = store.reader(hash);
    let mut header = [0u8; 12]; // 读 12 字节涵盖 WebP
    let n = reader.read(&mut header).await?;
    
    // 打印 Hex 日志方便调试
    sink.add("Header Hex: ".to_string() + &hex::encode(&header[..n])).ok();
    
    let mut ext = "bin";
    if n >= 3 && &header[0..3] == b"\xff\xd8\xff" {
        ext = "jpg";
    } else if n >= 8 && &header[0..8] == b"\x89PNG\r\n\x1a\n" {
        ext = "png";
    } else if n >= 6 && (&header[0..6] == b"GIF87a" || &header[0..6] == b"GIF89a") {
        ext = "gif";
    } else if n >= 12 && &header[0..4] == b"RIFF" && &header[8..12] == b"WEBP" {
        ext = "webp";
    } else if n >= 4 && &header[0..4] == b"%PDF" {
        ext = "pdf";
    }

    let export_filename = "received_".to_string() + &hex::encode(&hash.as_bytes()[..4]) + "." + ext;
    let export_path = PathBuf::from(&download_dir).join(export_filename);
    
    let mut reader = store.reader(hash);
    let mut file = tokio::fs::File::create(&export_path).await?;
    tokio::io::copy(&mut reader, &mut file).await?;

    sink.add("SUCCESS:Saved as .".to_string() + ext).ok();
    sink.add("Path: ".to_string() + &export_path.display().to_string()).ok();

    endpoint.close().await;
    Ok(())
}