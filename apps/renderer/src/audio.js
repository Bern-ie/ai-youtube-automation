// FFmpeg/ffprobe audio operations for the voiceover pipeline (Step 8).
// Every chunk is transcoded to a canonical WAV (PCM s16le, 44100Hz, mono)
// on storage so assembly is always a same-format concat, never a
// mixed-codec surprise — see docs/architecture/voiceover-pipeline.md#audio-format.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const execFileAsync = promisify(execFile);

export const CANONICAL_SAMPLE_RATE = 44100;
export const LOUDNESS_TARGET_LUFS = -16;

async function ffmpeg(args) {
  return execFileAsync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { maxBuffer: 1024 * 1024 * 64 });
}

async function ffprobeJson(file) {
  const { stdout } = await execFileAsync('ffprobe', [
    '-v', 'error', '-print_format', 'json',
    '-show_entries', 'stream=codec_name,codec_type,sample_rate:format=duration',
    file,
  ]);
  return JSON.parse(stdout);
}

export async function withTempDir(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'renderer-audio-'));
  try {
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

// Transcodes arbitrary provider audio (mp3/pcm/whatever) to the
// canonical WAV format. Returns ffprobe-derived facts about the
// transcoded file.
export async function transcodeToCanonicalWav(inputPath, outputPath) {
  await ffmpeg(['-i', inputPath, '-ac', '1', '-ar', String(CANONICAL_SAMPLE_RATE), '-c:a', 'pcm_s16le', outputPath]);
  return probe(outputPath);
}

export async function probe(filePath) {
  const info = await ffprobeJson(filePath);
  const audioStream = (info.streams || []).find((s) => s.codec_type === 'audio');
  return {
    hasAudioStream: Boolean(audioStream),
    codec: audioStream ? audioStream.codec_name : null,
    sampleRate: audioStream ? Number(audioStream.sample_rate) : null,
    durationSeconds: info.format && info.format.duration ? Number(info.format.duration) : null,
  };
}

// Parses ffmpeg's silencedetect filter stderr output into leading/
// trailing/longest-internal silence, in milliseconds. Conservative
// threshold (-35dB, 0.3s minimum) — flags genuinely excessive silence,
// not natural speech pauses.
export async function detectSilence(filePath, { noiseDb = -35, minDurationSeconds = 0.3 } = {}) {
  // ffmpeg with `-f null` exits 0 on success — silencedetect's events are
  // written to stderr regardless, so they must be read from the resolved
  // promise, not just from a thrown error's .stderr.
  let stderr = '';
  try {
    const result = await execFileAsync('ffmpeg', [
      '-i', filePath, '-af', `silencedetect=noise=${noiseDb}dB:d=${minDurationSeconds}`,
      '-f', 'null', '-',
    ], { maxBuffer: 1024 * 1024 * 64 });
    stderr = (result.stderr || '').toString();
  } catch (err) {
    stderr = (err.stderr || '').toString();
  }

  const events = [];
  const startRe = /silence_start:\s*([\d.]+)/g;
  const endRe = /silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)/g;
  const starts = [...stderr.matchAll(startRe)].map((m) => Number(m[1]));
  const ends = [...stderr.matchAll(endRe)].map((m) => ({ end: Number(m[1]), duration: Number(m[2]) }));

  for (let i = 0; i < ends.length; i += 1) {
    const start = starts[i] !== undefined ? starts[i] : ends[i].end - ends[i].duration;
    events.push({ startSeconds: start, endSeconds: ends[i].end, durationSeconds: ends[i].duration });
  }

  const totalDuration = (await probe(filePath)).durationSeconds || 0;
  const leadingSilenceMs = events.length && events[0].startSeconds < 0.05 ? Math.round(events[0].durationSeconds * 1000) : 0;
  const lastEvent = events[events.length - 1];
  const trailingSilenceMs = lastEvent && totalDuration && Math.abs(lastEvent.endSeconds - totalDuration) < 0.05
    ? Math.round(lastEvent.durationSeconds * 1000) : 0;
  const internalEvents = events.filter((e) => e !== events[0] || leadingSilenceMs === 0).filter((e) => e !== lastEvent || trailingSilenceMs === 0);
  const longestInternalSilenceMs = internalEvents.length ? Math.round(Math.max(...internalEvents.map((e) => e.durationSeconds)) * 1000) : 0;

  return {
    events, leadingSilenceMs, trailingSilenceMs, longestInternalSilenceMs,
    excessiveSilenceEvents: internalEvents.filter((e) => e.durationSeconds >= 2).length,
  };
}

// Concatenates same-format WAV files in the given order via the FFmpeg
// concat demuxer (a listed-file concat, not filter-graph concat — exact,
// lossless, and fast for identically-encoded inputs).
export async function concatWavFiles(inputPaths, outputPath, workDir) {
  const listPath = join(workDir, 'concat-list.txt');
  const listContent = inputPaths.map((p) => `file '${p.replace(/'/g, "'\\''")}'`).join('\n');
  await writeFile(listPath, listContent, 'utf8');
  await ffmpeg(['-f', 'concat', '-safe', '0', '-i', listPath, '-c', 'copy', outputPath]);
}

// Single-pass loudnorm to the documented -16 LUFS target (see
// docs/architecture/voiceover-pipeline.md#loudness-normalization).
export async function loudnormFile(inputPath, outputPath, targetLufs = LOUDNESS_TARGET_LUFS) {
  await ffmpeg(['-i', inputPath, '-af', `loudnorm=I=${targetLufs}:TP=-1.5:LRA=11`, '-ar', String(CANONICAL_SAMPLE_RATE), outputPath]);
}

export async function measureLoudness(filePath) {
  let stderr = '';
  try {
    const result = await execFileAsync('ffmpeg', ['-i', filePath, '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json', '-f', 'null', '-'], { maxBuffer: 1024 * 1024 * 64 });
    stderr = (result.stderr || '').toString();
  } catch (err) {
    stderr = (err.stderr || '').toString();
  }
  const match = stderr.match(/\{[^{}]*"input_i"[^{}]*\}/);
  if (!match) return { integratedLufs: null };
  try {
    const parsed = JSON.parse(match[0]);
    return { integratedLufs: Number(parsed.input_i) };
  } catch {
    return { integratedLufs: null };
  }
}

export async function transcodeToMp3(inputPath, outputPath) {
  await ffmpeg(['-i', inputPath, '-c:a', 'libmp3lame', '-b:a', '128k', outputPath]);
}

export function fileSizeBytes(path) {
  return statSync(path).size;
}

export { readFile, writeFile };
