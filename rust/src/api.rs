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
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use bytes::Bytes;
use std::sync::OnceLock;
use serde::{Serialize, Deserialize};
use iroh::protocol::AcceptError;

static IROH_NODE: OnceLock<IrohNode> = OnceLock::new();
static MSG_SINK: OnceLock<StreamSink<IncomingMessage>> = OnceLock::new();

const CHAT_ALPN: &[u8] = b"hole-chat/1";

// 暴露给 Dart 的消息结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncomingMessage {
    pub from: String,   // 发送者 NodeID
    pub text: String,   // 消息内容
    pub ticket: String, // 发送者的完整地址 Ticket，用于回信
}

// 内部网络传输的消息包装
#[derive(Serialize, Deserialize)]
struct WireMessage {
    text: String,
    sender_ticket: String,
}

struct IrohNode {
    router: iroh::protocol::Router,
    store: FsStore,
    root_dir: PathBuf,
}

fn get_node() -> Result<&'static IrohNode> {
    IROH_NODE.get().context("Node not initialized")
}

pub fn subscribe_messages(sink: StreamSink<IncomingMessage>) -> Result<()> {
    MSG_SINK.set(sink).ok().context("Already subscribed")?;
    Ok(())
}

pub async fn get_my_addr() -> Result<String> {
    let node = get_node()?;
    let addr = node.router.endpoint().addr();
    let ticket = BlobTicket::new(addr, iroh_blobs::Hash::from_bytes([0u8; 32]), BlobFormat::Raw);
    Ok(ticket.to_string())
}

pub async fn init_node(data_dir: String) -> Result<String> {
    if let Some(node) = IROH_NODE.get() {
        return Ok(node.router.endpoint().secret_key().public().to_string());
    }

    let root = PathBuf::from(&data_dir);
    tokio::fs::create_dir_all(&root).await?;

    let key_path = root.join("hole_secret_key");
    let secret_key = if key_path.exists() {
        let bytes = tokio::fs::read(&key_path).await?;
        SecretKey::try_from(bytes.as_slice()).context("Invalid secret key")? 
    } else {
        let key = SecretKey::generate(&mut rand::rng());
        tokio::fs::write(&key_path, key.to_bytes()).await?;
        key
    };

    let store_path = root.join("hole_store");
    tokio::fs::create_dir_all(&store_path).await?;
    let store = FsStore::load(&store_path).await?;

    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .discovery(PkarrPublisher::n0_dns())
        .alpns(vec![iroh_blobs::protocol::ALPN.to_vec(), CHAT_ALPN.to_vec()])
        .bind().await?;

    let chat_handler = ChatHandler;
    let blobs = BlobsProtocol::new(&store, None);
    let router = iroh::protocol::Router::builder(endpoint)
        .accept(iroh_blobs::ALPN, blobs)
        .accept(CHAT_ALPN, chat_handler)
        .spawn();

    router.endpoint().online().await;

    let node_id = router.endpoint().secret_key().public().to_string();
    let node = IrohNode { router, store, root_dir: root };
    IROH_NODE.set(node).ok().expect("Failed to set global node");

    Ok(node_id)
}

#[derive(Debug, Clone)]
struct ChatHandler;

impl iroh::protocol::ProtocolHandler for ChatHandler {
    fn accept(&self, conn: iroh::endpoint::Connection) -> futures::future::BoxFuture<'static, std::result::Result<(), AcceptError>> {
        Box::pin(async move {
            println!("DEBUG: [Rust] ChatHandler accepted connection from {}", conn.remote_id());
            let remote_node_id = conn.remote_id();
            let (_send, mut recv) = conn.accept_bi().await.map_err(AcceptError::from_err)?;
            
            // 读取消息长度
            let len = recv.read_u32().await.map_err(AcceptError::from_err)?;
            println!("DEBUG: [Rust] Incoming message length: {}", len);
            let mut buf = vec![0u8; len as usize];
            recv.read_exact(&mut buf).await.map_err(AcceptError::from_err)?;
            
            // 解析 JSON
            let wire_msg: WireMessage = serde_json::from_slice(&buf).map_err(|e| AcceptError::from_err(e))?;
            println!("DEBUG: [Rust] Parsed message from {}: {}", remote_node_id, wire_msg.text);
            
            if let Some(sink) = MSG_SINK.get() {
                sink.add(IncomingMessage {
                    from: remote_node_id.to_string(),
                    text: wire_msg.text,
                    ticket: wire_msg.sender_ticket,
                }).ok();
            }
            
            Ok(())
        })
    }
}

pub async fn send_text(target_ticket: String, my_ticket: String, text: String) -> Result<()> {
    println!("DEBUG: [Rust] send_text target_len={} my_len={} text_len={}", target_ticket.len(), my_ticket.len(), text.len());
    let node = get_node()?;
    
    // Defensive cleaning
    let target_ticket = if target_ticket.starts_with("TICKET:") {
        target_ticket[7..].to_string()
    } else {
        target_ticket
    };

    let ticket = BlobTicket::from_str(&target_ticket).context("Invalid target ticket")?;
    let addr = ticket.addr().clone();
    
    println!("DEBUG: [Rust] Connecting to {}...", addr);
    let conn = node.router.endpoint().connect(addr, CHAT_ALPN).await?;
    println!("DEBUG: [Rust] Connected to {}", conn.remote_id());
    
    let (mut send, _recv) = conn.open_bi().await?;
    
    let wire_msg = WireMessage {
        text,
        sender_ticket: my_ticket,
    };
    let bytes = serde_json::to_vec(&wire_msg)?;
    
    println!("DEBUG: [Rust] Writing {} bytes to stream", bytes.len());
    send.write_u32(bytes.len() as u32).await?;
    send.write_all(&bytes).await?;
    send.finish()?;
    println!("DEBUG: [Rust] Send finished successfully");
    
    Ok(())
}

pub async fn start_send(file_path: String, sink: StreamSink<String>) -> Result<()> {
    let node = get_node()?;
    let store = &node.store;
    
    let path = PathBuf::from(&file_path);
    if !path.exists() {
        sink.add("Error: File does not exist".to_string()).ok();
        return Ok(())
    }

    sink.add("Importing...".to_string()).ok();
    
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

    let filename = path.file_name().unwrap_or_default().to_string_lossy().to_string();
    let mut meta_name = "meta_".to_string();
    meta_name.push_str(&hex::encode(rand::random::<[u8; 4]>()));
    let meta_path = node.root_dir.join(meta_name);
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
    tokio::fs::remove_file(&meta_path).await.ok();

    let seq = HashSeq::from_iter([meta_hash, file_hash]);
    let mut seq_name = "seq_".to_string();
    seq_name.push_str(&hex::encode(rand::random::<[u8; 4]>()));
    let seq_path = node.root_dir.join(seq_name);
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
    tokio::fs::remove_file(&seq_path).await.ok();

    let endpoint = node.router.endpoint();
    let ticket = BlobTicket::new(endpoint.addr(), seq_hash, BlobFormat::HashSeq);
    
    sink.add("TICKET:".to_string() + &ticket.to_string()).ok();
    
    Ok(())
}

pub async fn receive_file(ticket_str: String, download_dir: String, sink: StreamSink<String>) -> Result<()> {
    let node = get_node()?;
    let store = &node.store;
    let endpoint = node.router.endpoint();

    let ticket = BlobTicket::from_str(&ticket_str).context("Invalid ticket")?;
    sink.add("Connecting...".to_string()).ok();
    
    let connection = endpoint.connect(ticket.addr().clone(), iroh_blobs::protocol::ALPN).await?;
    
    sink.add("Downloading...".to_string()).ok();
    let hash = ticket.hash();
    
    if ticket.format() == BlobFormat::HashSeq {
        let get_seq = store.remote().execute_get(connection.clone(), GetRequest::blob(hash));
        let mut stream = get_seq.stream();
        while let Some(item) = stream.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error Seq: ".to_string() + &e.to_string()).ok();
                 return Err(anyhow::anyhow!("Download Seq failed"));
             }
        }
        
        let mut reader = store.reader(hash);
        let mut seq_bytes = Vec::new();
        reader.read_to_end(&mut seq_bytes).await?;
        
        let seq = HashSeq::try_from(Bytes::from(seq_bytes))?;
        let hashes: Vec<_> = seq.into_iter().collect();
        
        if hashes.len() < 2 {
             return Err(anyhow::anyhow!("Invalid sequence length"));
        }
        let meta_hash = hashes[0];
        let file_hash = hashes[1];
        
        let get_meta = store.remote().execute_get(connection.clone(), GetRequest::blob(meta_hash));
        let mut stream_meta = get_meta.stream();
        while let Some(item) = stream_meta.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error Meta: ".to_string() + &e.to_string()).ok();
             }
        }
        let mut reader_meta = store.reader(meta_hash);
        let mut meta_bytes = Vec::new();
        reader_meta.read_to_end(&mut meta_bytes).await?;
        let filename = String::from_utf8_lossy(&meta_bytes).to_string();
        sink.add("Filename: ".to_string() + &filename).ok();

        let get_file = store.remote().execute_get(connection.clone(), GetRequest::blob(file_hash));
        let mut stream_file = get_file.stream();
        while let Some(item) = stream_file.next().await {
             if let iroh_blobs::api::remote::GetProgressItem::Error(e) = item {
                 sink.add("Error File: ".to_string() + &e.to_string()).ok();
                 return Err(anyhow::anyhow!("Download File failed"));
             }
        }
        
        let export_path = PathBuf::from(&download_dir).join(&filename);
        let mut reader_file = store.reader(file_hash);
        let mut file = tokio::fs::File::create(&export_path).await?;
        tokio::io::copy(&mut reader_file, &mut file).await?;

        sink.add("SUCCESS:Saved as ".to_string() + &filename).ok();
        sink.add("Path: ".to_string() + &export_path.display().to_string()).ok();

    } else {
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
        let mut header = [0u8; 12]; 
        let n = reader.read(&mut header).await?;
        
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

    Ok(())
}
