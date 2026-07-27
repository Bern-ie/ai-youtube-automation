// Automated FFmpeg capability smoke test.
//
// This does not just check that `ffmpeg` launches — it generates synthetic
// video/audio entirely inside the container (no fixture files), renders a
// real MP4 through a pipeline exercising H.264, AAC, scaling, overlay, and
// loudness normalization, then probes the result with ffprobe to confirm
// both streams actually exist. It then separately exercises subtitle
// burn-in, audio mixing, and crossfade transitions, since those are only
// used in specific render paths rather than every render.
//
// Exit code 0 means every required capability passed. Non-zero means at
// least one required capability failed — see the printed summary for which
// one and why. This must be run against the real built image (not assumed
// from `ffmpeg -version`) before that image's ARM64 support is marked
// verified in docs/architecture/arm64-compatibility.md.

import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { logger } from './logger.js';

const WORKDIR = process.env.FFMPEG_TEST_DIR || '/app/tmp/ffmpeg-capability-test';
const results = [];

function ffmpeg(args) {
  return execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...args], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
}

function ffprobeStreams(file) {
  const out = execFileSync('ffprobe', [
    '-v', 'error',
    '-show_entries', 'stream=codec_name,codec_type',
    '-of', 'json',
    file,
  ]).toString();
  return JSON.parse(out).streams || [];
}

function record(check, required, fn) {
  // Monotonic clock — Date.now() can jump backward under Docker
  // Desktop/WSL2 VM clock resyncs, which would otherwise produce a
  // negative duration here.
  const start = process.hrtime.bigint();
  try {
    fn();
    const duration_ms = Number(process.hrtime.bigint() - start) / 1e6;
    results.push({ check, status: 'pass', required, duration_ms });
    logger.info('ffmpeg capability check passed', { check, required, duration_ms });
  } catch (err) {
    const duration_ms = Number(process.hrtime.bigint() - start) / 1e6;
    const detail = err.stderr ? err.stderr.toString().slice(0, 1000) : err.message;
    results.push({ check, status: 'fail', required, duration_ms, error: detail });
    logger.error('ffmpeg capability check failed', { check, required, duration_ms, error: detail });
  }
}

function requireStreams(file, { video, audio }) {
  const streams = ffprobeStreams(file);
  if (video) {
    const v = streams.find((s) => s.codec_type === 'video');
    if (!v) throw new Error('expected a video stream, found none');
    if (video.codec && v.codec_name !== video.codec) {
      throw new Error(`expected video codec ${video.codec}, got ${v.codec_name}`);
    }
  }
  if (audio) {
    const a = streams.find((s) => s.codec_type === 'audio');
    if (!a) throw new Error('expected an audio stream, found none');
    if (audio.codec && a.codec_name !== audio.codec) {
      throw new Error(`expected audio codec ${audio.codec}, got ${a.codec_name}`);
    }
  }
  const stat = statSync(file);
  if (stat.size === 0) throw new Error('output file is empty');
}

function main() {
  rmSync(WORKDIR, { recursive: true, force: true });
  mkdirSync(WORKDIR, { recursive: true });

  let ffmpegVersion = 'unknown';
  try {
    ffmpegVersion = execFileSync('ffmpeg', ['-version']).toString().split('\n')[0];
  } catch {
    // handled by the required 'ffmpeg binary present' check below
  }

  record('ffmpeg binary present', true, () => {
    execFileSync('ffmpeg', ['-version']);
    execFileSync('ffprobe', ['-version']);
  });

  // --- Primary pipeline: covers steps 1-8 of the required capability list
  // in a single realistic render (synthetic video + audio generation,
  // H.264 encode, AAC encode, scale, overlay, loudnorm, MP4 output). ---
  const pipelineOut = join(WORKDIR, 'pipeline.mp4');
  record('primary render pipeline (video+audio gen, h264, aac, scale, overlay, loudnorm, mp4)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=2',
      '-f', 'lavfi', '-i', 'sine=frequency=1000:duration=2',
      '-f', 'lavfi', '-i', 'color=c=red:s=64x64:d=2',
      '-filter_complex',
      '[0:v]scale=160:120[scaled];[scaled][2:v]overlay=10:10[v];[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[a]',
      '-map', '[v]', '-map', '[a]',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '128k',
      '-movflags', '+faststart',
      '-t', '2',
      pipelineOut,
    ]);
  });

  // --- Steps 9-10: probe the pipeline output and verify both streams. ---
  record('ffprobe validates h264 video + aac audio streams', true, () => {
    requireStreams(pipelineOut, { video: { codec: 'h264' }, audio: { codec: 'aac' } });
  });

  // --- Voiceover pipeline (Step 8): WAV/PCM transcode, concat demuxer,
  // silencedetect -- the exact operations apps/renderer/src/audio.js runs
  // against provider TTS chunks. Covered separately from the primary
  // pipeline above since none of those ops appear in video rendering. ---
  const toneA = join(WORKDIR, 'tone-a.wav');
  const toneB = join(WORKDIR, 'tone-b.wav');
  record('WAV/PCM transcode (pcm_s16le, mono, 44.1kHz)', true, () => {
    ffmpeg(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', '-ac', '1', '-ar', '44100', '-c:a', 'pcm_s16le', toneA]);
    ffmpeg(['-f', 'lavfi', '-i', 'sine=frequency=880:duration=1', '-ac', '1', '-ar', '44100', '-c:a', 'pcm_s16le', toneB]);
    requireStreams(toneA, { audio: { codec: 'pcm_s16le' } });
  });

  const concatOut = join(WORKDIR, 'concat.wav');
  record('concatenation (concat demuxer, WAV chunks)', true, () => {
    const listPath = join(WORKDIR, 'concat-list.txt');
    writeFileSync(listPath, `file '${toneA}'\nfile '${toneB}'\n`, 'utf8');
    ffmpeg(['-f', 'concat', '-safe', '0', '-i', listPath, '-c', 'copy', concatOut]);
    requireStreams(concatOut, { audio: { codec: 'pcm_s16le' } });
  });

  record('silencedetect filter (leading/trailing silence analysis)', true, () => {
    const silentWav = join(WORKDIR, 'silence.wav');
    ffmpeg(['-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=mono', '-t', '1', '-c:a', 'pcm_s16le', silentWav]);
    // ffmpeg with -f null exits 0 regardless of what silencedetect finds --
    // the events land on stderr, so this check spawns directly rather than
    // via the throw-on-nonzero-exit ffmpeg() helper (matches audio.js's
    // detectSilence(), which reads stderr the same way).
    const proc = spawnSync('ffmpeg', [
      '-i', silentWav, '-af', 'silencedetect=noise=-30dB:d=0.1', '-f', 'null', '-',
    ], { encoding: 'utf8' });
    if (proc.status !== 0) throw new Error(`ffmpeg exited ${proc.status}: ${proc.stderr}`);
    if (!/silence_start/.test(proc.stderr)) throw new Error(`expected a silence_start event in stderr, got: ${proc.stderr.slice(0, 500)}`);
  });

  record('loudnorm measurement pass (JSON stats)', true, () => {
    execFileSync('ffmpeg', [
      '-i', toneA, '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json', '-f', 'null', '-',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
  });

  // --- Subtitle burn-in ---
  const srtPath = join(WORKDIR, 'test.srt');
  const subsOut = join(WORKDIR, 'subtitles.mp4');
  record('subtitle burn-in (subtitles filter)', true, () => {
    writeFileSync(
      srtPath,
      '1\n00:00:00,000 --> 00:00:02,000\nARM64 capability test\n',
      'utf8',
    );
    ffmpeg([
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=2',
      '-vf', `subtitles=${srtPath}`,
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-t', '2',
      subsOut,
    ]);
    requireStreams(subsOut, { video: { codec: 'h264' } });
  });

  // --- Audio mixing (amix) ---
  const amixOut = join(WORKDIR, 'amix.m4a');
  record('audio mixing (amix filter)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
      '-f', 'lavfi', '-i', 'sine=frequency=880:duration=2',
      '-filter_complex', 'amix=inputs=2:duration=first[a]',
      '-map', '[a]',
      '-c:a', 'aac',
      amixOut,
    ]);
    requireStreams(amixOut, { audio: { codec: 'aac' } });
  });

  // --- Transitions (xfade) ---
  const xfadeOut = join(WORKDIR, 'xfade.mp4');
  record('transitions (xfade filter)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'color=c=blue:s=160x120:d=2:r=25',
      '-f', 'lavfi', '-i', 'color=c=green:s=160x120:d=2:r=25',
      '-filter_complex', 'xfade=transition=fade:duration=1:offset=1[v]',
      '-map', '[v]',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      xfadeOut,
    ]);
    requireStreams(xfadeOut, { video: { codec: 'h264' } });
  });

  // --- Still-image motion (Step 10: zoompan, used by render.js's
  // motionFilter for slow_zoom_in/zoom_in/zoom_out/pan_* on stock images) ---
  const zoompanOut = join(WORKDIR, 'zoompan.mp4');
  record('still-image motion (zoompan filter)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'color=c=blue:s=320x240:d=2:r=25',
      '-vf', 'zoompan=z=\'min(zoom+0.0015,1.5)\':d=50:s=320x240:fps=25',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-t', '2',
      zoompanOut,
    ]);
    requireStreams(zoompanOut, { video: { codec: 'h264' } });
  });

  // --- Text overlays / spec-only text cards (Step 10: drawtext, used by
  // render.js's overlay_text handling and prepareSceneClip's chart/map/
  // text-card fallback rendering) ---
  const drawtextOut = join(WORKDIR, 'drawtext.mp4');
  record('text overlay (drawtext filter, DejaVu Sans Bold)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=1:r=25',
      '-vf', "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:text='ARM64 test':fontcolor=white:fontsize=24:x=10:y=10",
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-t', '1',
      drawtextOut,
    ]);
    requireStreams(drawtextOut, { video: { codec: 'h264' } });
  });

  // --- Background music ducking (Step 10: sidechaincompress, used by
  // render.js's prepareFinalAudio to duck music under narration) ---
  const duckOut = join(WORKDIR, 'duck.m4a');
  record('audio ducking (sidechaincompress filter)', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
      '-f', 'lavfi', '-i', 'sine=frequency=110:duration=2',
      '-filter_complex', '[1:a][0:a]sidechaincompress=threshold=0.05:ratio=8[ducked]',
      '-map', '[ducked]',
      '-c:a', 'aac',
      duckOut,
    ]);
    requireStreams(duckOut, { audio: { codec: 'aac' } });
  });

  // --- Multi-clip concat+xfade chain with timebase normalization (Step 10:
  // this is the exact scenario that surfaced a real bug in render.js's
  // combineScenesWithTransitions — a `cut` transition's concat output fed
  // into a later `xfade` failed with a timebase mismatch until every input
  // was normalized via fps=+settb=AVTB first. This check reproduces that
  // three-clip cut-then-dissolve chain to catch a regression of the same
  // class on either platform.) ---
  const chainOut = join(WORKDIR, 'chain.mp4');
  record('multi-clip concat+xfade chain with settb=AVTB normalization', true, () => {
    ffmpeg([
      '-f', 'lavfi', '-i', 'color=c=red:s=160x120:d=1:r=25',
      '-f', 'lavfi', '-i', 'color=c=green:s=160x120:d=1:r=25',
      '-f', 'lavfi', '-i', 'color=c=blue:s=160x120:d=1:r=25',
      '-filter_complex',
      '[0:v]fps=25,settb=AVTB[n0];[1:v]fps=25,settb=AVTB[n1];[2:v]fps=25,settb=AVTB[n2];' +
      '[n0][n1]concat=n=2:v=1:a=0[cut01];' +
      '[cut01]settb=AVTB[cut01tb];' +
      '[cut01tb][n2]xfade=transition=dissolve:duration=0.5:offset=1.5[v]',
      '-map', '[v]',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      chainOut,
    ]);
    requireStreams(chainOut, { video: { codec: 'h264' } });
  });

  rmSync(WORKDIR, { recursive: true, force: true });

  const requiredResults = results.filter((r) => r.required);
  const allRequiredPassed = requiredResults.every((r) => r.status === 'pass');

  logger.info('ffmpeg capability test summary', {
    ffmpeg_version: ffmpegVersion,
    all_required_passed: allRequiredPassed,
    results,
  });

  // Human-readable summary on stdout in addition to the structured log line.
  process.stdout.write('\n=== FFmpeg capability test summary ===\n');
  process.stdout.write(`${ffmpegVersion}\n`);
  for (const r of results) {
    const mark = r.status === 'pass' ? 'PASS' : 'FAIL';
    process.stdout.write(`[${mark}] ${r.check} (${r.duration_ms}ms)\n`);
    if (r.status === 'fail') process.stdout.write(`       ${r.error}\n`);
  }
  process.stdout.write(allRequiredPassed ? '\nRESULT: ALL REQUIRED CAPABILITIES PASSED\n' : '\nRESULT: FAILED\n');

  process.exit(allRequiredPassed ? 0 : 1);
}

main();
