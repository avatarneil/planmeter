//! Just enough HTTP/1.1 for the control socket: one request per connection,
//! `Connection: close`, JSON bodies. Used by the client and the mock daemon.

use std::io::{self, BufRead, BufReader, Read, Write};

/// Bodies larger than this are refused rather than buffered.
pub const MAX_BODY: usize = 64 * 1024 * 1024;
const MAX_HEADER_LINE: usize = 16 * 1024;
const MAX_HEADERS: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub reason: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }

    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }
}

fn find_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

pub fn write_request(
    out: &mut impl Write,
    method: &str,
    path: &str,
    body: Option<&[u8]>,
) -> io::Result<()> {
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: planmeter-gtk/{}\r\nAccept: application/json\r\nConnection: close\r\n",
        env!("CARGO_PKG_VERSION")
    );
    match body {
        Some(body) => head.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )),
        None if method == "POST" || method == "PUT" => head.push_str("Content-Length: 0\r\n\r\n"),
        None => head.push_str("\r\n"),
    }
    out.write_all(head.as_bytes())?;
    if let Some(body) = body {
        out.write_all(body)?;
    }
    out.flush()
}

pub fn write_response(out: &mut impl Write, status: u16, body: &[u8]) -> io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        reason(status),
        body.len()
    );
    out.write_all(head.as_bytes())?;
    out.write_all(body)?;
    out.flush()
}

pub fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn read_line(reader: &mut impl BufRead) -> io::Result<String> {
    let mut line = Vec::new();
    let n = reader
        .by_ref()
        .take(MAX_HEADER_LINE as u64 + 1)
        .read_until(b'\n', &mut line)?;
    if n == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "connection closed",
        ));
    }
    if line.len() > MAX_HEADER_LINE {
        return Err(invalid("header line too long"));
    }
    while matches!(line.last(), Some(b'\n' | b'\r')) {
        line.pop();
    }
    String::from_utf8(line).map_err(|_| invalid("header is not UTF-8"))
}

fn read_headers(reader: &mut impl BufRead) -> io::Result<Vec<(String, String)>> {
    let mut headers = Vec::new();
    loop {
        let line = read_line(reader)?;
        if line.is_empty() {
            return Ok(headers);
        }
        if headers.len() >= MAX_HEADERS {
            return Err(invalid("too many headers"));
        }
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| invalid(format!("malformed header {line:?}")))?;
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }
}

fn read_body(
    reader: &mut impl BufRead,
    headers: &[(String, String)],
    until_eof: bool,
) -> io::Result<Vec<u8>> {
    let chunked = find_header(headers, "transfer-encoding")
        .is_some_and(|v| v.to_ascii_lowercase().contains("chunked"));
    if chunked {
        return read_chunked(reader);
    }
    if let Some(length) = find_header(headers, "content-length") {
        let length: usize = length.parse().map_err(|_| invalid("bad Content-Length"))?;
        if length > MAX_BODY {
            return Err(invalid("body too large"));
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body)?;
        return Ok(body);
    }
    let mut body = Vec::new();
    if until_eof {
        reader.take(MAX_BODY as u64 + 1).read_to_end(&mut body)?;
        if body.len() > MAX_BODY {
            return Err(invalid("body too large"));
        }
    }
    Ok(body)
}

fn read_chunked(reader: &mut impl BufRead) -> io::Result<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let line = read_line(reader)?;
        let size_text = line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16).map_err(|_| invalid("bad chunk size"))?;
        if size == 0 {
            // Trailers, then the final blank line.
            while !read_line(reader)?.is_empty() {}
            return Ok(body);
        }
        let start = body.len();
        let end = start
            .checked_add(size)
            .filter(|&end| end <= MAX_BODY)
            .ok_or_else(|| invalid("body too large"))?;
        body.resize(end, 0);
        reader.read_exact(&mut body[start..])?;
        let mut crlf = [0u8; 2];
        reader.read_exact(&mut crlf)?;
        if &crlf != b"\r\n" {
            return Err(invalid("chunk without CRLF"));
        }
    }
}

pub fn read_response(stream: impl Read) -> io::Result<Response> {
    let mut reader = BufReader::new(stream);
    let status_line = read_line(&mut reader)?;
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().unwrap_or("");
    if !version.starts_with("HTTP/1.") {
        return Err(invalid(format!("not an HTTP response: {status_line:?}")));
    }
    let status: u16 = parts
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| invalid("bad status code"))?;
    let reason = parts.next().unwrap_or("").to_string();
    let headers = read_headers(&mut reader)?;
    let body = if status == 204 || status == 304 {
        Vec::new()
    } else {
        read_body(&mut reader, &headers, true)?
    };
    Ok(Response {
        status,
        reason,
        headers,
        body,
    })
}

pub fn read_request(stream: impl Read) -> io::Result<Request> {
    let mut reader = BufReader::new(stream);
    let line = read_line(&mut reader)?;
    let mut parts = line.split(' ');
    let method = parts
        .next()
        .filter(|m| !m.is_empty())
        .ok_or_else(|| invalid("missing method"))?
        .to_string();
    let path = parts
        .next()
        .ok_or_else(|| invalid("missing path"))?
        .to_string();
    let headers = read_headers(&mut reader)?;
    let body = read_body(&mut reader, &headers, false)?;
    Ok(Request {
        method,
        path,
        headers,
        body,
    })
}

/// Percent-encodes one path segment, keeping only RFC 3986 unreserved
/// characters, as `planmeterd` does (`codex:plan:work` → `codex%3Aplan%3Awork`).
pub fn encode_segment(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for b in segment.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Decodes `%XX` escapes in a path segment.
pub fn decode_segment(segment: &str) -> String {
    let bytes = segment.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip() {
        let mut buf = Vec::new();
        write_request(
            &mut buf,
            "PUT",
            "/v1/settings/spend",
            Some(br#"{"groups":["work"]}"#),
        )
        .unwrap();
        let text = String::from_utf8(buf.clone()).unwrap();
        assert!(text.starts_with("PUT /v1/settings/spend HTTP/1.1\r\n"));
        assert!(text.contains("Connection: close\r\n"));
        let req = read_request(&buf[..]).unwrap();
        assert_eq!(req.method, "PUT");
        assert_eq!(req.path, "/v1/settings/spend");
        assert_eq!(req.body, br#"{"groups":["work"]}"#);
    }

    #[test]
    fn bodyless_post_sends_zero_length() {
        let mut buf = Vec::new();
        write_request(&mut buf, "POST", "/v1/remote/invite", None).unwrap();
        assert!(String::from_utf8(buf)
            .unwrap()
            .contains("Content-Length: 0\r\n\r\n"));
    }

    #[test]
    fn response_with_content_length() {
        let mut buf = Vec::new();
        write_response(&mut buf, 404, br#"{"error":"not found"}"#).unwrap();
        let res = read_response(&buf[..]).unwrap();
        assert_eq!(res.status, 404);
        assert!(!res.is_success());
        assert_eq!(res.body, br#"{"error":"not found"}"#);
        assert_eq!(res.header("content-type"), Some("application/json"));
    }

    #[test]
    fn chunked_and_eof_bodies() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n";
        assert_eq!(read_response(&raw[..]).unwrap().body, b"{\"a\":1}");
        let raw = b"HTTP/1.0 200 OK\r\n\r\n{\"b\":2}";
        assert_eq!(read_response(&raw[..]).unwrap().body, b"{\"b\":2}");
    }

    #[test]
    fn rejects_oversized_chunks() {
        // A huge second chunk must not wrap the length and panic.
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\nffffffffffffffff\r\nb\r\n0\r\n\r\n";
        assert!(read_response(&raw[..]).is_err());
        let raw = format!(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n",
            MAX_BODY + 1
        );
        assert!(read_response(raw.as_bytes()).is_err());
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naXY0\r\n\r\n";
        assert!(read_response(&raw[..]).is_err());
    }

    #[test]
    fn rejects_garbage() {
        assert!(read_response(&b"SSH-2.0-OpenSSH\r\n\r\n"[..]).is_err());
        assert!(read_response(&b""[..]).is_err());
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 999999999999\r\n\r\n";
        assert!(read_response(&raw[..]).is_err());
    }

    #[test]
    fn path_segments() {
        assert_eq!(encode_segment("codex:plan:work"), "codex%3Aplan%3Awork");
        assert_eq!(
            encode_segment("claude:home:/home/dev/.claude"),
            "claude%3Ahome%3A%2Fhome%2Fdev%2F.claude"
        );
        assert_eq!(decode_segment("codex%3Aplan%3Awork"), "codex:plan:work");
        assert_eq!(encode_segment("a b/c"), "a%20b%2Fc");
        assert_eq!(decode_segment("a%20b%2Fc"), "a b/c");
        assert_eq!(decode_segment("100%"), "100%");
    }
}
