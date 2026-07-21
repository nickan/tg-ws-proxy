//! tg-ws-proxy — Lightweight Telegram MTProxy WebSocket Bypass Relay in Rust
//!
//! Architecture:
//!   Client ──[FakeTLS TCP]──► [tg-ws-proxy :8443] ──[WSS WebSocket]──► Cloudflare ──► Telegram DC
//!

use std::{
    net::SocketAddr,
    sync::Arc,
    time::Duration,
};

use aes::cipher::{KeyIvInit, StreamCipher};
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use tokio::{
    io::{self, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::Message,
};

type HmacSha256 = Hmac<Sha256>;
type Aes256Ctr = ctr::Ctr128BE<aes::Aes256>;

const SECRET_LEN: usize = 16;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const WS_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

const DOMAINS: &[&str] = &[
    "cakeisalie.co.uk",
    "noskomnadzor.co.uk",
    "pyatdesyatdva.co.uk",
    "notelega.co.uk",
    "nebally.co.uk",
    "stopblocking.co.uk",
    "pyatdesyatodin.co.uk",
    "sorokdva.co.uk",
];

#[derive(Clone)]
struct Config {
    port: u16,
    secret: Arc<[u8; SECRET_LEN]>,
}

// ─── Entry Point ─────────────────────────────────────────────────────────────

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let cfg = parse_args();
    let addr = SocketAddr::from(([0, 0, 0, 0], cfg.port));

    let listener = TcpListener::bind(addr)
        .await
        .unwrap_or_else(|e| panic!("Failed to bind {addr}: {e}"));

    println!("[tg-ws-proxy] Listening on {addr}");
    println!("[tg-ws-proxy] Secret: {}", hex::encode(cfg.secret.as_ref()));

    let cfg = Arc::new(cfg);
    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, peer)) => {
                        let cfg = Arc::clone(&cfg);
                        tokio::spawn(async move {
                            if let Err(e) = handle_client(stream, peer, cfg).await {
                                eprintln!("[{peer}] error: {e}");
                            }
                        });
                    }
                    Err(e) => eprintln!("[accept] {e}"),
                }
            }
            _ = tokio::signal::ctrl_c() => {
                println!("[tg-ws-proxy] Shutting down…");
                break;
            }
        }
    }
}

// ─── FakeTLS verification helpers ─────────────────────────────────────────────

fn verify_client_hello(data: &[u8], secret: &[u8]) -> Option<(Vec<u8>, Vec<u8>, u32)> {
    if data.len() < 43 { return None; }
    if data[0] != 0x16 { return None; }
    if data[5] != 0x01 { return None; }

    let client_random = data[11..43].to_vec();
    let mut zeroed = data.to_vec();
    zeroed[11..43].copy_from_slice(&[0u8; 32]);

    let mut mac = HmacSha256::new_from_slice(secret).ok()?;
    mac.update(&zeroed);
    let expected = mac.finalize().into_bytes();

    if expected[..28] != client_random[..28] {
        return None;
    }

    let mut ts_xor = [0u8; 4];
    for i in 0..4 {
        ts_xor[i] = client_random[28 + i] ^ expected[28 + i];
    }
    let timestamp = u32::from_le_bytes(ts_xor);

    let mut session_id = vec![0u8; 32];
    if data.len() >= 44 + 32 && data[43] == 0x20 {
        session_id.copy_from_slice(&data[44..76]);
    }

    Some((client_random, session_id, timestamp))
}

fn build_server_hello(secret: &[u8], client_random: &[u8], session_id: &[u8]) -> Vec<u8> {
    let mut sh = vec![
        0x16, 0x03, 0x03, 0x00, 0x7a,
        0x02, 0x00, 0x00, 0x76,
        0x03, 0x03,
    ];
    sh.extend_from_slice(&[0u8; 32]); // placeholder for server random
    sh.push(0x20); // session id length
    sh.extend_from_slice(session_id);
    sh.extend_from_slice(&[0x13, 0x01, 0x00, 0x00, 0x2e, 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20]);

    let mut pubkey = [0u8; 32];
    let _ = getrandom::getrandom(&mut pubkey);
    sh.extend_from_slice(&pubkey);
    sh.extend_from_slice(&[0x00, 0x2b, 0x00, 0x02, 0x03, 0x04]);

    let ccs = vec![0x14, 0x03, 0x03, 0x00, 0x01, 0x01];

    let encrypted_size = 2000;
    let mut encrypted_data = vec![0u8; encrypted_size];
    let _ = getrandom::getrandom(&mut encrypted_data);

    let mut app_record = vec![0x17, 0x03, 0x03];
    app_record.extend_from_slice(&(encrypted_size as u16).to_be_bytes());
    app_record.extend_from_slice(&encrypted_data);

    let mut response = sh.clone();
    response.extend_from_slice(&ccs);
    response.extend_from_slice(&app_record);

    let mut hmac_input = client_random.to_vec();
    hmac_input.extend_from_slice(&response);

    let mut mac = HmacSha256::new_from_slice(secret).unwrap();
    mac.update(&hmac_input);
    let server_random = mac.finalize().into_bytes();

    response[11..43].copy_from_slice(&server_random);
    response
}

fn wrap_tls_record(data: &[u8]) -> Vec<u8> {
    let mut parts = Vec::new();
    let mut offset = 0;
    while offset < data.len() {
        let chunk_size = std::cmp::min(data.len() - offset, 16384);
        let chunk = &data[offset..offset + chunk_size];
        parts.push(0x17);
        parts.push(0x03);
        parts.push(0x03);
        parts.extend_from_slice(&(chunk_size as u16).to_be_bytes());
        parts.extend_from_slice(chunk);
        offset += chunk_size;
    }
    parts
}

// ─── FakeTLS StreamReader/StreamWriter wrapper ───────────────────────────────

struct FakeTlsReader<R> {
    inner: R,
    read_buf: Vec<u8>,
    read_left: usize,
}

impl<R> FakeTlsReader<R>
where
    R: AsyncRead + Unpin,
{
    fn new(inner: R) -> Self {
        Self {
            inner,
            read_buf: Vec::new(),
            read_left: 0,
        }
    }

    async fn read_exactly(&mut self, n: usize) -> io::Result<Vec<u8>> {
        while self.read_buf.len() < n {
            let payload = self.read_tls_payload().await?;
            if payload.is_empty() {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Incomplete read"));
            }
            self.read_buf.extend_from_slice(&payload);
        }
        let result = self.read_buf[..n].to_vec();
        self.read_buf.drain(..n);
        Ok(result)
    }

    async fn read_tls_payload(&mut self) -> io::Result<Vec<u8>> {
        if self.read_left > 0 {
            let mut buf = vec![0u8; self.read_left];
            let n = self.inner.read(&mut buf).await?;
            if n == 0 { return Ok(Vec::new()); }
            self.read_left -= n;
            buf.truncate(n);
            return Ok(buf);
        }

        loop {
            let mut hdr = [0u8; 5];
            self.inner.read_exact(&mut hdr).await?;
            let rtype = hdr[0];
            let rec_len = u16::from_be_bytes([hdr[3], hdr[4]]) as usize;

            if rtype == 0x14 {
                if rec_len > 0 {
                    let mut tmp = vec![0u8; rec_len];
                    self.inner.read_exact(&mut tmp).await?;
                }
                continue;
            }

            if rtype != 0x17 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "Expected TLS AppData"));
            }

            let mut data = vec![0u8; rec_len];
            self.inner.read_exact(&mut data).await?;
            return Ok(data);
        }
    }
}

struct FakeTlsWriter<W> {
    inner: W,
}

impl<W> FakeTlsWriter<W>
where
    W: AsyncWrite + Unpin,
{
    fn new(inner: W) -> Self {
        Self { inner }
    }

    async fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        let record = wrap_tls_record(data);
        self.inner.write_all(&record).await
    }

    async fn flush(&mut self) -> io::Result<()> {
        self.inner.flush().await
    }
}

// ─── obfs2 & MTProto Deobfuscation Helpers ─────────────────────────────────────

fn try_handshake(handshake: &[u8; 64], secret: &[u8]) -> Option<(i16, bool, [u8; 4], Vec<u8>)> {
    let dec_prekey_and_iv = handshake[8..56].to_vec();
    let dec_prekey = &dec_prekey_and_iv[..32];
    let dec_iv = &dec_prekey_and_iv[32..48];

    let mut hasher = Sha256::new();
    hasher.update(dec_prekey);
    hasher.update(secret);
    let dec_key = hasher.finalize();

    let mut cipher = Aes256Ctr::new_from_slices(&dec_key, dec_iv).ok()?;
    let mut decrypted = *handshake;
    cipher.apply_keystream(&mut decrypted);

    let proto_tag: [u8; 4] = decrypted[56..60].try_into().ok()?;

    let abridged = [0xef, 0xef, 0xef, 0xef];
    let intermediate = [0xee, 0xee, 0xee, 0xee];
    let secure = [0xdd, 0xdd, 0xdd, 0xdd];

    if proto_tag != abridged && proto_tag != intermediate && proto_tag != secure {
        return None;
    }

    let dc_idx = i16::from_le_bytes([decrypted[60], decrypted[61]]);
    let dc_id = dc_idx.abs();
    let is_media = dc_idx < 0;

    Some((dc_id, is_media, proto_tag, dec_prekey_and_iv))
}

fn generate_relay_init(proto_tag: [u8; 4], dc_idx: i16) -> Vec<u8> {
    let mut rnd = [0u8; 64];
    loop {
        let _ = getrandom::getrandom(&mut rnd);
        if rnd[0] == 0xef { continue; }
        let start: [u8; 4] = rnd[..4].try_into().unwrap();
        if start == [0x48, 0x45, 0x41, 0x44] || start == [0x50, 0x4f, 0x53, 0x54]
           || start == [0x47, 0x45, 0x54, 0x20] || start == [0xee, 0xee, 0xee, 0xee]
           || start == [0xdd, 0xdd, 0xdd, 0xdd] || start == [0x16, 0x03, 0x01, 0x02] {
            continue;
        }
        if rnd[4..8] == [0, 0, 0, 0] { continue; }
        break;
    }

    let enc_key = &rnd[8..40];
    let enc_iv = &rnd[40..56];

    let mut cipher = Aes256Ctr::new_from_slices(enc_key, enc_iv).unwrap();
    let mut encrypted_full = rnd;
    cipher.apply_keystream(&mut encrypted_full);

    let mut keystream_tail = [0u8; 8];
    for i in 0..8 {
        keystream_tail[i] = encrypted_full[56 + i] ^ rnd[56 + i];
    }

    let dc_bytes = dc_idx.to_le_bytes();
    let mut tail_plain = [0u8; 8];
    tail_plain[..4].copy_from_slice(&proto_tag);
    tail_plain[4..6].copy_from_slice(&dc_bytes);

    let mut rand_tail = [0u8; 2];
    let _ = getrandom::getrandom(&mut rand_tail);
    tail_plain[6..8].copy_from_slice(&rand_tail);

    let mut encrypted_tail = [0u8; 8];
    for i in 0..8 {
        encrypted_tail[i] = tail_plain[i] ^ keystream_tail[i];
    }

    let mut result = rnd.to_vec();
    result[56..64].copy_from_slice(&encrypted_tail);
    result
}

// ─── Crypto Context ───────────────────────────────────────────────────────────

// ─── Crypto Context ───────────────────────────────────────────────────────────

fn build_crypto_ctx(client_dec_prekey_iv: &[u8], secret: &[u8], relay_init: &[u8]) -> (Aes256Ctr, Aes256Ctr, Aes256Ctr, Aes256Ctr) {
    // Client decryptor
    let clt_dec_prekey = &client_dec_prekey_iv[..32];
    let clt_dec_iv = &client_dec_prekey_iv[32..48];
    let mut hasher = Sha256::new();
    hasher.update(clt_dec_prekey);
    hasher.update(secret);
    let clt_dec_key = hasher.finalize();

    // Client encryptor
    let mut reversed = client_dec_prekey_iv.to_vec();
    reversed.reverse();
    let clt_enc_prekey = &reversed[..32];
    let clt_enc_iv = &reversed[32..48];
    let mut hasher = Sha256::new();
    hasher.update(clt_enc_prekey);
    hasher.update(secret);
    let clt_enc_key = hasher.finalize();

    let mut clt_dec = Aes256Ctr::new_from_slices(&clt_dec_key, clt_dec_iv).unwrap();
    let clt_enc = Aes256Ctr::new_from_slices(&clt_enc_key, clt_enc_iv).unwrap();

    // Skip first 64 bytes of client decryption
    let mut zero_64 = [0u8; 64];
    clt_dec.apply_keystream(&mut zero_64);

    // Telegram side (standard obfs2 keys)
    let relay_enc_key = &relay_init[8..40];
    let relay_enc_iv = &relay_init[40..56];

    let mut relay_dec_prekey_iv = relay_init[8..56].to_vec();
    relay_dec_prekey_iv.reverse();
    let relay_dec_key = &relay_dec_prekey_iv[..32];
    let relay_dec_iv = &relay_dec_prekey_iv[32..48];

    let mut tg_enc = Aes256Ctr::new_from_slices(relay_enc_key, relay_enc_iv).unwrap();
    let tg_dec = Aes256Ctr::new_from_slices(relay_dec_key, relay_dec_iv).unwrap();

    // Skip first 64 bytes of telegram encryption
    let mut zero_64_tg = [0u8; 64];
    tg_enc.apply_keystream(&mut zero_64_tg);

    (clt_dec, clt_enc, tg_enc, tg_dec)
}

// ─── MsgSplitter ──────────────────────────────────────────────────────────────

struct MsgSplitter {
    proto: [u8; 4],
    cipher_buf: Vec<u8>,
    plain_buf: Vec<u8>,
    dec: Aes256Ctr,
}

impl MsgSplitter {
    fn new(client_dec_prekey_iv: &[u8], secret: &[u8], proto: [u8; 4]) -> Self {
        let clt_dec_prekey = &client_dec_prekey_iv[..32];
        let clt_dec_iv = &client_dec_prekey_iv[32..48];
        let mut hasher = Sha256::new();
        hasher.update(clt_dec_prekey);
        hasher.update(secret);
        let clt_dec_key = hasher.finalize();

        let mut dec = Aes256Ctr::new_from_slices(&clt_dec_key, clt_dec_iv).unwrap();
        let mut zero_64 = [0u8; 64];
        dec.apply_keystream(&mut zero_64);

        Self {
            proto,
            cipher_buf: Vec::new(),
            plain_buf: Vec::new(),
            dec,
        }
    }

    fn split(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.cipher_buf.extend_from_slice(chunk);
        let mut plain = chunk.to_vec();
        self.dec.apply_keystream(&mut plain);
        self.plain_buf.extend_from_slice(&plain);

        let mut parts = Vec::new();
        let mut offset = 0;

        let abridged = [0xef, 0xef, 0xef, 0xef];
        let intermediate = [0xee, 0xee, 0xee, 0xee];
        let secure = [0xdd, 0xdd, 0xdd, 0xdd];

        while offset < self.cipher_buf.len() {
            let avail = self.cipher_buf.len() - offset;
            let packet_len = if self.proto == abridged {
                let first = self.plain_buf[offset];
                if first == 0x7f || first == 0xff {
                    if avail < 4 { break; }
                    let len_bytes: [u8; 4] = [
                        self.plain_buf[offset + 1],
                        self.plain_buf[offset + 2],
                        self.plain_buf[offset + 3],
                        0,
                    ];
                    let payload_len = u32::from_le_bytes(len_bytes) as usize * 4;
                    4 + payload_len
                } else {
                    let payload_len = (first & 0x7f) as usize * 4;
                    1 + payload_len
                }
            } else if self.proto == intermediate || self.proto == secure {
                if avail < 4 { break; }
                let len_bytes: [u8; 4] = self.plain_buf[offset..offset+4].try_into().unwrap();
                let payload_len = (u32::from_le_bytes(len_bytes) & 0x7fffffff) as usize;
                4 + payload_len
            } else {
                break;
            };

            if avail < packet_len {
                break;
            }

            parts.push(self.cipher_buf[offset..offset + packet_len].to_vec());
            offset += packet_len;
        }

        if offset > 0 {
            self.cipher_buf.drain(..offset);
            self.plain_buf.drain(..offset);
        }
        parts
    }
}

// ─── Connection Handler ───────────────────────────────────────────────────────

async fn handle_client(
    mut client: TcpStream,
    peer: SocketAddr,
    cfg: Arc<Config>,
) -> io::Result<()> {
    client.set_nodelay(true)?;

    // 1. Read TLS ClientHello
    let mut initial_hdr = [0u8; 5];
    timeout(HANDSHAKE_TIMEOUT, client.read_exact(&mut initial_hdr))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ClientHello header timeout"))??;

    if initial_hdr[0] != 0x16 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Expected TLS Handshake"));
    }

    let record_len = u16::from_be_bytes([initial_hdr[3], initial_hdr[4]]) as usize;
    let mut client_hello = vec![0u8; record_len];
    timeout(HANDSHAKE_TIMEOUT, client.read_exact(&mut client_hello))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ClientHello body timeout"))??;

    let mut full_hello = initial_hdr.to_vec();
    full_hello.extend_from_slice(&client_hello);

    let (client_random, session_id, _) = verify_client_hello(&full_hello, cfg.secret.as_ref())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid FakeTLS ClientHello"))?;

    // 2. Reply ServerHello
    let server_hello = build_server_hello(cfg.secret.as_ref(), &client_random, &session_id);
    client.write_all(&server_hello).await?;

    // 3. Read client's obfs2 handshake inside TLS Wrapper
    let mut tls_reader = FakeTlsReader::new(client);
    let handshake_bytes = tls_reader.read_exactly(64).await?;
    let handshake: [u8; 64] = handshake_bytes.try_into().unwrap();

    let (dc_id, is_media, proto_tag, client_dec_prekey_iv) = try_handshake(&handshake, cfg.secret.as_ref())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid obfs2 handshake inside TLS"))?;

    println!("[{peer}] → DC{} (media={})", dc_id, is_media);

    // 4. Connect to Cloudflare fronting WebSocket
    let mut ws_stream = None;
    for &domain in DOMAINS {
        // Build websocket target domain
        let target_domain = format!("kws{dc_id}.{domain}");
        let ws_url = format!("wss://{target_domain}/apiws");
        println!("[{peer}] Trying domain: {}", target_domain);

        match timeout(WS_CONNECT_TIMEOUT, connect_async(&ws_url)).await {
            Ok(Ok((ws, _))) => {
                ws_stream = Some(ws);
                break;
            }
            Ok(Err(e)) => println!("[{peer}] WSS connect failed on {target_domain}: {e}"),
            Err(_) => println!("[{peer}] WSS connect timed out on {target_domain}"),
        }
    }

    let mut ws = ws_stream.ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "All WSS domains failed"))?;

    // 5. Generate and send Telegram-side obfuscation handshake
    let dc_idx = if is_media { -dc_id } else { dc_id };
    let relay_init = generate_relay_init(proto_tag, dc_idx);
    ws.send(Message::Binary(relay_init.clone())).await
        .map_err(|e| io::Error::new(io::ErrorKind::WriteZero, format!("WS write error: {e}")))?;

    // 6. Build Cryptography & Splitter
    let (mut clt_dec, mut clt_enc, mut tg_enc, mut tg_dec) = build_crypto_ctx(&client_dec_prekey_iv, cfg.secret.as_ref(), &relay_init);
    let mut splitter = MsgSplitter::new(&client_dec_prekey_iv, cfg.secret.as_ref(), proto_tag);

    // 7. Split FakeTlsStream into Reader & Writer
    let (cr, cw) = tokio::io::split(tls_reader.inner);
    let mut tls_reader = FakeTlsReader::new(cr);
    let mut tls_writer = FakeTlsWriter::new(cw);

    let (mut ws_sink, mut ws_stream) = ws.split();

    // 8. Relay tasks
    let client_to_ws = async move {
        loop {
            let payload = tls_reader.read_tls_payload().await?;
            if payload.is_empty() { break; }
            let mut plain = payload;
            clt_dec.apply_keystream(&mut plain); // decrypt

            let mut cipher = plain;
            tg_enc.apply_keystream(&mut cipher); // encrypt

            let parts = splitter.split(&cipher);
            for part in parts {
                ws_sink.send(Message::Binary(part)).await
                    .map_err(|e| io::Error::new(io::ErrorKind::WriteZero, format!("WS send error: {e}")))?;
            }
        }
        Ok::<(), io::Error>(())
    };

    let ws_to_client = async move {
        while let Some(msg) = ws_stream.next().await {
            let msg = msg.map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("WS read error: {e}")))?;
            match msg {
                Message::Binary(data) => {
                    let mut plain = data;
                    tg_dec.apply_keystream(&mut plain); // decrypt

                    let mut cipher = plain;
                    clt_enc.apply_keystream(&mut cipher); // encrypt

                    tls_writer.write_all(&cipher).await?;
                    tls_writer.flush().await?;
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        Ok::<(), io::Error>(())
    };

    tokio::select! {
        res = client_to_ws => { res?; }
        res = ws_to_client => { res?; }
    }

    Ok(())
}

// ─── Command Line Parser ──────────────────────────────────────────────────────

fn parse_args() -> Config {
    let mut args = pico_args::Arguments::from_env();

    if args.contains(["-h", "--help"]) {
        println!("{}", concat!(
            "Usage: tg-ws-proxy [--port <PORT>] [--secret <HEX>]\n",
            "\n",
            "Options:\n",
            "  --port    Listening port (default: 8443)\n",
            "  --secret  16-byte MTProxy secret as 32 hex chars\n",
            "            (default: ee155b2ebbd93854830e71195db68a6cdd)\n"
        ));
        std::process::exit(0);
    }

    let port: u16 = args.opt_value_from_str("--port")
        .expect("invalid --port value")
        .unwrap_or(8443);

    let secret_hex: String = args.opt_value_from_str("--secret")
        .expect("invalid --secret value")
        .unwrap_or_else(|| "ee155b2ebbd93854830e71195db68a6cdd".to_string());

    let secret_trimmed = secret_hex.trim().trim_start_matches("0x");
    let decoded = hex::decode(secret_trimmed)
        .unwrap_or_else(|e| panic!("Secret must be valid hex chars: '{}' (error: {})", secret_trimmed, e));

    if decoded.len() != SECRET_LEN {
        panic!("Secret must be exactly 16 bytes (32 hex characters). Got {} bytes from '{}'", decoded.len(), secret_trimmed);
    }

    let mut secret = [0u8; SECRET_LEN];
    secret.copy_from_slice(&decoded);

    Config {
        port,
        secret: Arc::new(secret),
    }
}
