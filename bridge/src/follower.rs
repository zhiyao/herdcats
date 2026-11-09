use crate::{
    Result,
    claude::{Entry, Transcript},
};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Seek, SeekFrom},
    os::unix::fs::{FileExt, MetadataExt},
    path::Path,
};
/// Whole-file limit for agents whose transcripts are reread in full each poll.
/// Claude and Codex transcripts are read tail-first and have no size limit.
pub const MAX_SOURCE: u64 = 64 * 1024 * 1024;
pub const MAX_RECORD: usize = 1024 * 1024;
/// Records shown first to the phone; also the minimum a fresh timeline loads.
pub const PAGE: usize = 100;
/// Tail the already resolved and verified adapter file; no path lookup occurs.
/// Ignore the first possibly partial line and any unfinished final record.
pub fn read_tail(file: fs::File) -> Result<Vec<serde_json::Value>> {
    read_tail_within(file, 4 * 1024 * 1024)
}

/// Records whose lines lie entirely in the last `limit` bytes of the file.
pub fn read_tail_within(mut file: fs::File, limit: u64) -> Result<Vec<serde_json::Value>> {
    let metadata = file.metadata().map_err(|_| "transcript_unavailable")?;
    if !metadata.is_file() {
        return Err("transcript_unavailable");
    }
    let start = metadata.len().saturating_sub(limit);
    file.seek(SeekFrom::Start(start))
        .map_err(|_| "transcript_unavailable")?;
    let mut bytes = Vec::new();
    file.take(limit).read_to_end(&mut bytes)
        .map_err(|_| "transcript_unavailable")?;
    let mut lines = bytes.split_inclusive(|b| *b == b'\n');
    if start > 0 {
        lines.next();
    }
    Ok(lines.filter(|line| line.last() == Some(&b'\n'))
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect())
}

/// Reads exactly `start..end`; a file that shrank underneath reads as changing.
fn read_range(file: &fs::File, start: u64, end: u64, buf: &mut Vec<u8>) -> Result<()> {
    let len = usize::try_from(end.saturating_sub(start)).map_err(|_| "transcript_unavailable")?;
    buf.clear();
    buf.resize(len, 0);
    file.read_exact_at(buf, start).map_err(|e| {
        if e.kind() == std::io::ErrorKind::UnexpectedEof { "source_changing" } else { "transcript_unavailable" }
    })
}

#[derive(Clone, Debug, PartialEq)]
struct Stamp {
    dev: u64,
    ino: u64,
    len: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}

impl Stamp {
    fn of(m: &fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            mtime: (m.mtime(), m.mtime_nsec()),
            ctime: (m.ctime(), m.ctime_nsec()),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub enum AgentType {
    #[default]
    Claude,
    Codex,
    Agy,
    Pi,
    Cursor,
}

/// Byte budgets for reading append-only Claude and Codex transcripts tail-first.
#[derive(Clone, Copy, Debug)]
pub struct Windows {
    /// Bytes read from the end of the file when a timeline starts or resets.
    pub tail: u64,
    /// Bytes read per older batch.
    pub chunk: u64,
    /// Newest consumed bytes compared again on every poll.
    pub verify: u64,
    /// Leading file bytes compared again on every poll.
    pub head: u64,
}
impl Default for Windows {
    fn default() -> Self {
        Self {
            tail: 8 * 1024 * 1024,
            chunk: 4 * 1024 * 1024,
            verify: 8 * 1024 * 1024,
            head: 64 * 1024,
        }
    }
}

#[derive(Default)]
pub struct Follower {
    pub agent_type: AgentType,
    preserve_content: bool,
    pub transcript: Transcript,
    /// Absolute file offset just past the last consumed record.
    pub offset: u64,
    pub generation: u64,
    stamp: Option<Stamp>,
    /// Consumed bytes compared again on every poll, starting at `bytes_base`.
    /// Whole-file agents keep the complete prefix; tail-first agents keep the
    /// newest `Windows::verify` to `2 * verify` bytes.
    bytes: Vec<u8>,
    bytes_base: u64,
    /// Leading file bytes, compared on every poll once `bytes_base` is past 0.
    head: Vec<u8>,
    session: String,
    pi_branch_ids: Vec<String>,
    buf: Vec<u8>,
    /// Absolute file offset of `buf[0]` during a pass.
    buf_base: u64,
    /// Unconsumed bytes after `bytes` at the last pass: an unfinished line or,
    /// for Cursor, the volatile final record. Equal bytes mean nothing new.
    tail: Vec<u8>,
    windows: Windows,
    /// The verified source, kept to read older batches and content.
    source: Option<fs::File>,
    /// Entries older than `transcript.entries`, oldest first.
    older: Vec<Entry>,
    /// Bytes before this offset are not yet parsed into `older`.
    floor: u64,
    /// Parsed records that update entries from unread older bytes; see
    /// `Transcript::deferred`.
    deferred: Vec<(Option<String>, u64, usize)>,
}
impl Follower {
    pub fn for_agent(agent_type: AgentType) -> Self {
        Self {
            agent_type,
            ..Self::default()
        }
    }
    pub fn with_content() -> Self {
        Self {
            preserve_content: true,
            ..Self::default()
        }
    }
    pub fn with_content_for_agent(agent_type: AgentType) -> Self {
        Self {
            agent_type,
            preserve_content: true,
            ..Self::default()
        }
    }
    /// Overrides the tail-first byte budgets.
    pub fn with_windows(mut self, windows: Windows) -> Self {
        self.windows = windows;
        self
    }
    /// Claude and Codex append to their transcripts, so they are read
    /// tail-first; other agents are reread in full under `MAX_SOURCE`.
    pub fn windowed(&self) -> bool {
        matches!(self.agent_type, AgentType::Claude | AgentType::Codex)
    }
    /// Entries older than the live list, oldest first.
    pub fn older(&self) -> &[Entry] {
        &self.older
    }
    /// Whether file bytes before `older()` remain to be loaded.
    pub fn has_unread_older(&self) -> bool {
        self.floor > 0
    }
    /// Loads older batches until `older()` holds `want` entries or the file
    /// start is reached. Returns how many entries were added.
    pub fn load_older(&mut self, want: usize) -> Result<usize> {
        let mut added = 0;
        let mut read = 0;
        while self.older.len() < want && self.floor > 0 {
            // Bound one request's I/O once it has something to show.
            if added > 0 && read >= 8 * self.windows.chunk {
                break;
            }
            let (count, bytes) = self.load_older_chunk()?;
            added += count;
            read += bytes;
        }
        Ok(added)
    }
    fn load_older_chunk(&mut self) -> Result<(usize, u64)> {
        let file = self.source.as_ref().ok_or("transcript_unavailable")?;
        let end = self.floor;
        let mut bytes = Vec::new();
        let mut size = self.windows.chunk.max(1);
        // `end` is always a line start; widen until a whole line fits.
        let (from, start) = loop {
            let raw = end.saturating_sub(size);
            let from = raw.saturating_sub(1);
            read_range(file, from, end, &mut bytes)?;
            if raw == 0 {
                break (0, 0);
            }
            match bytes.iter().position(|b| *b == b'\n') {
                Some(i) if i + 1 < bytes.len() => break (from, i + 1),
                _ => size = size.saturating_mul(2),
            }
        };
        let chunk_start = from + start as u64;
        let mut batch = Transcript {
            uncapped: true,
            partial_prefix: chunk_start > 0,
            ..Transcript::default()
        };
        self.consume_lines(&mut batch, &bytes, from, start, &self.session, |_| false)?;
        let read = end - chunk_start;
        // Newer records that updated this batch's entries before they were
        // loaded (results, later outputs, turn aborts), replayed in file order.
        let created: HashSet<&str> = batch.entries.iter().map(|e| e.id.as_str()).collect();
        let running = batch.has_running_tools();
        let mut replay: Vec<(u64, usize)> = self
            .deferred
            .iter()
            .filter(|(key, _, _)| key.as_deref().map_or(running, |key| created.contains(key)))
            .map(|(_, offset, len)| (*offset, *len))
            .collect();
        drop(created);
        replay.sort_unstable();
        replay.dedup();
        batch.update_only = true;
        for (offset, len) in replay {
            read_range(file, offset, offset + len as u64, &mut bytes)?;
            self.apply_line(&mut batch, &bytes, offset, &self.session)?;
        }
        self.deferred.append(&mut batch.deferred);
        let known: HashSet<&str> = self
            .older
            .iter()
            .chain(&self.transcript.entries)
            .map(|e| e.id.as_str())
            .collect();
        let entries: Vec<Entry> = batch
            .entries
            .into_iter()
            .filter(|e| !known.contains(e.id.as_str()))
            .collect();
        if self.older.len() + entries.len() > 100_000 {
            return Err("transcript_identity_limit");
        }
        let count = entries.len();
        self.older.splice(0..0, entries);
        self.floor = chunk_start;
        Ok((count, read))
    }
    pub fn read_content(&self, reference: &str, offset: usize) -> Result<(Vec<u8>, usize)> {
        if !self.transcript.entries.iter().chain(&self.older).any(|entry| {
            entry.content_ref.as_deref() == Some(reference)
                || entry.record_refs.iter().any(|r| r == reference)
        }) {
            return Err("content_unavailable");
        }
        let mut parts = reference.split(':');
        if parts.next() != Some("source") {
            return Err("content_unavailable");
        }
        let start = parts
            .next()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or("content_unavailable")?;
        let length = parts
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .ok_or("content_unavailable")?;
        if parts.next().is_some() || offset > length {
            return Err("invalid_content_offset");
        }
        let end = start
            .checked_add(length as u64)
            .filter(|end| *end <= self.offset)
            .ok_or("content_unavailable")?;
        let next = offset.saturating_add(64 * 1024).min(length);
        let cached_end = self.bytes_base + self.bytes.len() as u64;
        if start >= self.bytes_base && end <= cached_end {
            let at = (start - self.bytes_base) as usize;
            return Ok((self.bytes[at + offset..at + next].to_vec(), length));
        }
        // Older bytes are no longer cached; read them from the verified source.
        let file = self.source.as_ref().filter(|_| self.windowed()).ok_or("content_unavailable")?;
        let mut chunk = Vec::new();
        read_range(file, start + offset as u64, start + next as u64, &mut chunk)
            .map_err(|_| "content_unavailable")?;
        Ok((chunk, length))
    }
    pub fn refresh_pi_entries(&mut self, entries: &[serde_json::Value], session: &str) -> Result<bool> {
        let mut transcript = Transcript::default();
        let header = serde_json::json!({"type":"session","id":session});
        transcript.apply_pi(&header, session)?;
        for row in entries { transcript.apply_pi(row, session)?; }
        // Streaming entries are temporary projections, not native branch nodes.
        let branch_ids: Vec<String> = entries.iter()
            .filter_map(|row| row["id"].as_str())
            .filter(|id| !id.starts_with("herdcats-live:"))
            .map(str::to_owned).collect();
        let reset = self.session != session || !branch_ids.starts_with(&self.pi_branch_ids);
        let changed = reset || self.transcript.entries != transcript.entries;
        if reset {
            self.generation += 1;
            self.offset = 0;
            self.bytes.clear();
            self.bytes_base = 0;
            self.stamp = None;
        }
        self.pi_branch_ids = branch_ids;
        self.transcript = transcript;
        self.session = session.to_owned();
        Ok(changed)
    }
    /// Action guard: accepts an append, but rejects rotation or any modification
    /// to the verified bytes that authorized the displayed request/generation.
    pub fn verify_source(&self, file: fs::File) -> Result<()> {
        let before=Stamp::of(&file.metadata().map_err(|_|"stale")?);
        let cached=self.stamp.as_ref().ok_or("stale")?;
        let cached_end=self.bytes_base+self.bytes.len() as u64;
        if before.dev!=cached.dev || before.ino!=cached.ino || before.len<cached_end
            || (!self.windowed() && before.len>MAX_SOURCE) {return Err("stale");}
        let mut bytes=Vec::new();
        read_range(&file,self.bytes_base,cached_end,&mut bytes).map_err(|_|"stale")?;
        let mut head=Vec::new();
        if self.bytes_base>0 {read_range(&file,0,self.head.len() as u64,&mut head).map_err(|_|"stale")?;}
        let after=Stamp::of(&file.metadata().map_err(|_|"stale")?);
        if before!=after || bytes!=self.bytes || (self.bytes_base>0 && head!=self.head) {return Err("stale");}
        Ok(())
    }
    pub fn refresh(&mut self, path: &Path, session: &str) -> Result<bool> {
        self.refresh_file(crate::resolver::open_absolute(path, false)?, session)
    }
    pub fn refresh_file(&mut self, file: fs::File, session: &str) -> Result<bool> {
        if self.windowed() {
            return self.refresh_windowed(file, session);
        }
        let before = Stamp::of(&file.metadata().map_err(|_| "transcript_unavailable")?);
        if before.len > MAX_SOURCE {
            return Err("source_too_large");
        }
        // Retaining a bounded prefix lets us distinguish append from any rewrite,
        // including truncate/regrow between polls or edits earlier in the file.
        // Equal metadata stamps can hide same-length rewrites on filesystems with
        // coarse timestamps, so every poll rereads up to MAX_SOURCE bytes. This
        // bounded I/O cost is necessary to verify the cached content is current.
        // Reusing a preallocated buffer avoids bounded allocator churn across
        // frequent idle polls (which drove resident memory up to ~1.28 GB when
        // allocating and discarding large buffers repeatedly under the allocator,
        // rather than an unbounded memory leak). Steady-state memory footprint is
        // bounded by two retained buffers: `buf` (for reading) and `bytes` (prefix
        // cache). Their lengths are capped at MAX_SOURCE (64 MiB); Vec capacity may
        // round upward. Temporary parsing allocations add to that footprint.
        self.buf.clear();
        self.buf.reserve((before.len as usize).saturating_add(1));
        (&file)
            .take(MAX_SOURCE + 1)
            .read_to_end(&mut self.buf)
            .map_err(|_| "transcript_unavailable")?;
        if self.buf.len() as u64 > MAX_SOURCE {
            return Err("source_too_large");
        }
        let after = Stamp::of(&file.metadata().map_err(|_| "transcript_unavailable")?);
        if before != after {
            return Err("source_changing");
        }
        self.buf_base = 0;
        let reset = self
            .stamp
            .as_ref()
            .is_none_or(|old| old.dev != before.dev || old.ino != before.ino)
            || self.session != session
            || !self.buf.starts_with(&self.bytes);

        if !reset && self.buf[self.bytes.len()..] == self.tail[..] {
            self.stamp = Some(before);
            return Ok(false);
        }

        let mut transcript = if reset {
            Transcript::default()
        } else {
            self.transcript.clone()
        };
        let start = if reset { 0 } else { self.bytes.len() };
        let consumed = self.consume_lines(&mut transcript, &self.buf, 0, start, session, |_| false)?;
        if reset {
            self.generation += 1;
            self.bytes.clear();
        }
        let cached = self.bytes.len();
        self.bytes.extend_from_slice(&self.buf[cached..consumed]);
        self.finish_pass(transcript, consumed, before, file, session, reset)
    }
    fn refresh_windowed(&mut self, file: fs::File, session: &str) -> Result<bool> {
        let before = Stamp::of(&file.metadata().map_err(|_| "transcript_unavailable")?);
        let continuing = self
            .stamp
            .as_ref()
            .is_some_and(|old| old.dev == before.dev && old.ino == before.ino)
            && self.session == session
            && before.len >= self.offset;
        if !continuing {
            return self.restart(file, session, before);
        }
        // A rewrite anywhere is caught if it touches the head or the newest
        // consumed bytes; Claude and Codex only append, so the middle is not
        // reread on every poll.
        let mut head = Vec::new();
        if self.bytes_base > 0 {
            read_range(&file, 0, self.head.len() as u64, &mut head)?;
        }
        let mut buf = std::mem::take(&mut self.buf);
        let read = read_range(&file, self.bytes_base, before.len, &mut buf);
        self.buf = buf;
        read?;
        self.buf_base = self.bytes_base;
        let after = Stamp::of(&file.metadata().map_err(|_| "transcript_unavailable")?);
        if before != after {
            return Err("source_changing");
        }
        if (self.bytes_base > 0 && head != self.head) || !self.buf.starts_with(&self.bytes) {
            return self.restart(file, session, before);
        }
        if self.buf[self.bytes.len()..] == self.tail[..] {
            self.stamp = Some(before);
            self.source = Some(file);
            return Ok(false);
        }
        let mut transcript = self.transcript.clone();
        let cached = self.bytes.len();
        let consumed = self.consume_lines(&mut transcript, &self.buf, self.buf_base, cached, session, |_| false)?;
        self.bytes.extend_from_slice(&self.buf[cached..consumed]);
        self.finish_pass(transcript, consumed, before, file, session, false)
    }
    /// Starts a timeline from the newest `Windows::tail` bytes, at a line start.
    fn restart(&mut self, file: fs::File, session: &str, before: Stamp) -> Result<bool> {
        let len = before.len;
        let mut size = self.windows.tail.max(1);
        let mut buf = std::mem::take(&mut self.buf);
        let found = loop {
            let raw = len.saturating_sub(size);
            // Include the preceding byte to tell whether `raw` starts a line.
            let from = raw.saturating_sub(1);
            if let Err(code) = read_range(&file, from, len, &mut buf) {
                break Err(code);
            }
            if raw == 0 {
                break Ok((0, 0));
            }
            match buf.iter().position(|b| *b == b'\n') {
                Some(i) => break Ok((from, i + 1)),
                None => size = size.saturating_mul(2),
            }
        };
        self.buf = buf;
        let (buf_base, start) = found?;
        let after = Stamp::of(&file.metadata().map_err(|_| "transcript_unavailable")?);
        if before != after {
            return Err("source_changing");
        }
        let base = buf_base + start as u64;
        let mut head = Vec::new();
        if base > 0 {
            read_range(&file, 0, self.windows.head.min(len), &mut head)?;
        }
        self.buf_base = buf_base;
        let mut transcript = Transcript {
            spill: true,
            partial_prefix: base > 0,
            ..Transcript::default()
        };
        let consumed = self.consume_lines(&mut transcript, &self.buf, buf_base, start, session, |_| false)?;
        self.generation += 1;
        self.head = head;
        self.bytes.clear();
        self.bytes.extend_from_slice(&self.buf[start..consumed]);
        self.bytes_base = base;
        self.older.clear();
        self.deferred.clear();
        self.floor = base;
        self.finish_pass(transcript, consumed, before, file, session, true)
    }
    fn finish_pass(
        &mut self,
        mut transcript: Transcript,
        consumed: usize,
        stamp: Stamp,
        file: fs::File,
        session: &str,
        reset: bool,
    ) -> Result<bool> {
        let changed = reset
            || transcript.entries != self.transcript.entries
            || transcript.unknown_records != self.transcript.unknown_records;
        self.older.append(&mut transcript.spilled);
        self.deferred.append(&mut transcript.deferred);
        self.offset = self.buf_base + consumed as u64;
        self.tail.clear();
        self.tail.extend_from_slice(&self.buf[consumed..]);
        if self.windowed() && self.bytes.len() as u64 > 2 * self.windows.verify {
            if self.bytes_base == 0 {
                let head = (self.windows.head as usize).min(self.bytes.len());
                self.head = self.bytes[..head].to_vec();
            }
            let excess = self.bytes.len() - self.windows.verify as usize;
            self.bytes.drain(..excess);
            self.bytes_base += excess as u64;
        }
        self.transcript = transcript;
        self.stamp = Some(stamp);
        self.session = session.to_owned();
        self.source = self.windowed().then_some(file);
        Ok(changed)
    }
    /// Applies complete lines of `bytes` from index `start`, where `bytes[0]`
    /// is at file offset `base`. Stops before a line once `done` holds.
    /// Returns the index just past the last consumed line.
    fn consume_lines(
        &self,
        transcript: &mut Transcript,
        bytes: &[u8],
        base: u64,
        start: usize,
        session: &str,
        mut done: impl FnMut(&Transcript) -> bool,
    ) -> Result<usize> {
        let mut index = start;
        for part in bytes[start..].split_inclusive(|b| *b == b'\n') {
            if part.last() != Some(&b'\n') || done(transcript) {
                break;
            }
            // Cursor overwrites its trailing `turn_ended` marker in place when
            // the next prompt starts, and that write can be observed torn.
            // A final complete line that is the marker or unparsable is held
            // back, not consumed: the next pass rewinds to this line's start,
            // and the unchanged prefix never counts as a rewrite.
            if self.agent_type == AgentType::Cursor
                && part != b"\n"
                && index + part.len() == bytes.len()
                && part.len() <= MAX_RECORD
                && serde_json::from_slice::<serde_json::Value>(part)
                    .map_or(true, |row| crate::cursor::is_turn_end(&row))
            {
                break;
            }
            if part != b"\n" {
                self.apply_line(transcript, part, base + index as u64, session)?;
            }
            index += part.len();
        }
        Ok(index)
    }
    fn apply_line(&self, transcript: &mut Transcript, part: &[u8], offset: u64, session: &str) -> Result<()> {
        let offset_usize = usize::try_from(offset).map_err(|_| "source_too_large")?;
        transcript.origin = offset;
        transcript.record_len = part.len();
        let result = match self.agent_type {
            AgentType::Agy => {
                if part.len() > MAX_RECORD { return Err("record_too_large"); }
                let row = serde_json::from_slice(part).map_err(|_| "invalid_transcript")?;
                transcript.apply_agy(&row, offset_usize, part.len(), self.preserve_content)
            },
            AgentType::Cursor => {
                if part.len() > MAX_RECORD { return Err("record_too_large"); }
                let row = serde_json::from_slice(part).map_err(|_| "invalid_transcript")?;
                transcript.apply_cursor(&row, offset_usize, part.len(), self.preserve_content)
            },
            AgentType::Claude => {
                if part.len() > MAX_RECORD {
                    transcript.apply_oversized(part, session)
                } else {
                    let row =
                        serde_json::from_slice(part).map_err(|_| "invalid_transcript")?;
                    transcript.apply(&row, session)
                }
            }
            AgentType::Codex => {
                if part.len() > MAX_RECORD {
                    transcript.apply_codex_oversized(part, session, offset_usize)
                } else {
                    let row =
                        serde_json::from_slice(part).map_err(|_| "invalid_transcript")?;
                    transcript.apply_codex(&row, session, offset_usize)
                }
            }
            AgentType::Pi => {
                if part.len() > MAX_RECORD { return Err("record_too_large"); }
                let row = serde_json::from_slice(part).map_err(|_| "invalid_transcript")?;
                transcript.apply_pi(&row, session)
            }
        };
        // Valid but unfamiliar message shapes remain inspectable as raw
        // records. Ownership/security and resource-limit errors still fail.
        if let Err(code) = result {
            if code != "invalid_transcript" || !self.preserve_content {
                return Err(code);
            }
        }
        if self.preserve_content {
            match self.agent_type {
                AgentType::Agy | AgentType::Cursor => {},
                AgentType::Claude => transcript.preserve_record(part, session, offset_usize)?,
                AgentType::Codex => {
                    transcript.preserve_codex_record(part, session, offset_usize)?
                }
                AgentType::Pi => transcript.preserve_pi_record(part, session, offset_usize)?,
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "follower_window_tests.rs"]
mod window_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_length_rewrite_is_detected_when_metadata_stamps_collide() {
        struct TempFile(std::path::PathBuf);
        impl Drop for TempFile {
            fn drop(&mut self) {
                let _ = fs::remove_file(&self.0);
            }
        }
        let path = TempFile(std::env::temp_dir().join(format!(
            "hc-follower-stamp-collision-{}",
            std::process::id()
        )));
        let session = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
        let record = |text| {
            format!(
                "{}\n",
                serde_json::json!({"type":"user","uuid":"same","sessionId":session,
                    "message":{"role":"user","content":text}})
            )
        };
        let old = record("old");
        let new = record("new");
        assert_eq!(old.len(), new.len());
        fs::write(&path.0, &old).unwrap();
        let source_path = path.0.canonicalize().unwrap();
        let mut follower = Follower::default();
        assert!(follower.refresh(&source_path, session).unwrap());
        assert_eq!(follower.transcript.entries[0].text, "old");
        let generation = follower.generation;
        fs::write(&path.0, &new).unwrap();
        // Model a filesystem whose timestamp resolution cannot distinguish these
        // same-length writes, while leaving the cached source bytes untouched.
        follower.stamp = Some(Stamp::of(&fs::metadata(&path.0).unwrap()));
        assert!(follower.refresh(&source_path, session).unwrap());
        assert_eq!(follower.transcript.entries.len(), 1);
        assert_eq!(follower.transcript.entries[0].text, "new");
        assert_eq!(follower.generation, generation + 1);
        assert!(!follower.refresh(&source_path, session).unwrap());
        assert_eq!(follower.generation, generation + 1);
    }
}
