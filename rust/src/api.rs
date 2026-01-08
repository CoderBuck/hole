use crate::frb_generated::StreamSink;
use anyhow::{Context, Result};
use futures::StreamExt;
use iroh::{discovery::pkarr::PkarrPublisher, Endpoint, SecretKey};
use iroh_blobs::api::blobs::{AddPathOptions, ImportMode};
use iroh_blobs::{BlobFormat, hashseq::HashSeq};
use iroh_blobs::protocol::GetRequest;
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::ticket::BlobTicket;
use iroh_blobs::BlobsProtocol;
use std::path::PathBuf;
use std::str::FromStr;
use tokio::io::AsyncReadExt;
use bytes::Bytes;

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
    
    // 1. Import File
    let import = store.add_path_with_opts(AddPathOptions {
        path: path.clone(),
        mode: ImportMode::TryReference,
        format: BlobFormat::Raw,
    });
    
    let mut stream = import.stream().await;
    let mut file_hash = None;
    while let Some(item) = stream.next().await {
        if let iroh_blobs::api::blobs::AddProgressItem::Done(t) = item {
             file_hash = Some(t.hash());
        }
    }
    let file_hash = file_hash.context("Import failed")?;

    // 2. Import Metadata (Filename)
    let filename = path.file_name().unwrap_or_default().to_string_lossy().to_string();
    let meta_path = data_path.join("temp_meta_blob");
    tokio::fs::write(&meta_path, filename.as_bytes()).await?;

    let import_meta = store.add_path_with_opts(AddPathOptions {
        path: meta_path.clone(),
        mode: ImportMode::Copy,
        format: BlobFormat::Raw,
    });
    let mut stream_meta = import_meta.stream().await;
    let mut meta_hash = None;
    while let Some(item) = stream_meta.next().await {
        if let iroh_blobs::api::blobs::AddProgressItem::Done(t) = item {
             meta_hash = Some(t.hash());
        }
    }
    let meta_hash = meta_hash.context("Meta import failed")?;

    // 3. Create HashSeq [meta, file]
    let seq = HashSeq::from_iter([meta_hash, file_hash]);
    let seq_path = data_path.join("temp_seq_blob");
    tokio::fs::write(&seq_path, Bytes::from(seq)).await?;

    let import_seq = store.add_path_with_opts(AddPathOptions {
        path: seq_path.clone(),
        mode: ImportMode::Copy,
        format: BlobFormat::HashSeq,
    });
    let mut stream_seq = import_seq.stream().await;
    let mut seq_hash = None;
    while let Some(item) = stream_seq.next().await {
        if let iroh_blobs::api::blobs::AddProgressItem::Done(t) = item {
             seq_hash = Some(t.hash());
        }
    }
    let seq_hash = seq_hash.context("Seq import failed")?;

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

    // Ticket now points to the HashSeq
    let ticket = BlobTicket::new(ep.addr(), seq_hash, BlobFormat::HashSeq);
    sink.add(format!("DEBUG: Generated Ticket Format: {:?}", ticket.format())).ok();
    sink.add("TICKET:".to_string() + &ticket.to_string()).ok();
    sink.add("Ready!".to_string()).ok();

    futures::future::pending::<()>().await;
    router.shutdown().await?;
    Ok(())
}

pub async fn receive_file(ticket_str: String, data_dir: String, download_dir: String, sink: StreamSink<String>) -> Result<()> {
    let ticket = BlobTicket::from_str(&ticket_str).context("Invalid ticket")?;
    sink.add(format!("DEBUG: Received Ticket Format: {:?}", ticket.format())).ok();
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
    
    if ticket.format() == BlobFormat::HashSeq {
        // --- New Protocol: HashSeq [Meta, File] ---
        
        // 1. Download Sequence
        let get_seq = store.remote().execute_get(connection.clone(), GetRequest::blob(hash));
        let mut stream = get_seq.stream();
        while let Some(item) = stream.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error Seq: ".to_string() + &e.to_string()).ok();
                 return Err(anyhow::anyhow!("Download Seq failed"));
             }
        }
        
        // 2. Parse Sequence
        let mut reader = store.reader(hash);
        let mut seq_bytes = Vec::new();
        reader.read_to_end(&mut seq_bytes).await?;
        
        // HashSeq usually implements Into<Bytes> via `into_bytes()` or `to_bytes()`.
        // In iroh-blobs 0.97, it's `into_bytes()`.
        let seq = HashSeq::try_from(Bytes::from(seq_bytes))?;
        let hashes: Vec<_> = seq.into_iter().collect();
        
        if hashes.len() < 2 {
             return Err(anyhow::anyhow!("Invalid sequence length"));
        }
        let meta_hash = hashes[0];
        let file_hash = hashes[1];
        
        // 3. Download Metadata
        let get_meta = store.remote().execute_get(connection.clone(), GetRequest::blob(meta_hash));
        let mut stream_meta = get_meta.stream();
        while let Some(item) = stream_meta.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error Meta: ".to_string() + &e.to_string()).ok();
                 // Continue? Might fail.
             }
        }
        let mut reader_meta = store.reader(meta_hash);
        let mut meta_bytes = Vec::new();
        reader_meta.read_to_end(&mut meta_bytes).await?;
        let filename = String::from_utf8_lossy(&meta_bytes).to_string();
        sink.add("Filename: ".to_string() + &filename).ok();

        // 4. Download File
        let get_file = store.remote().execute_get(connection.clone(), GetRequest::blob(file_hash));
        let mut stream_file = get_file.stream();
        while let Some(item) = stream_file.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error File: ".to_string() + &e.to_string()).ok();
                 return Err(anyhow::anyhow!("Download File failed"));
             }
        }
        
        // 5. Export
        let export_path = PathBuf::from(&download_dir).join(&filename);
        let mut reader_file = store.reader(file_hash);
        let mut file = tokio::fs::File::create(&export_path).await?;
        tokio::io::copy(&mut reader_file, &mut file).await?;

        sink.add("SUCCESS:Saved as ".to_string() + &filename).ok();
        sink.add("Path: ".to_string() + &export_path.display().to_string()).ok();

    } else {
        // --- Old Protocol: Raw Blob ---
        
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
        sink.add("Header Hex: ".to_string() + &hex::encode(&header[..n]) + "\n").ok();
        
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

    }

    endpoint.close().await;
    Ok(())
}
