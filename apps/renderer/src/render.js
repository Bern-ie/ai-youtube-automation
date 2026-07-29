// Deterministic scene-manifest-to-MP4 rendering engine for the video
// render pipeline (Step 10). n8n orchestrates (claims jobs, persists
// results); this module does all real FFmpeg composition work --
// per-scene clip preparation (scale/crop/motion/overlay), transition
// chaining (concat for cuts, xfade for dissolve/fade/zoom), audio
// mixing/ducking/loudness, subtitle burn-in, final mux, and the
// deterministic decode/codec/black-frame validation the render QC
// function consumes. See docs/architecture/video-render-pipeline.md.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { probe, sha256, fileSizeBytes } from './audio.js';
import { getObjectBuffer, putObject } from './storage.js';

const execFileAsync = promisify(execFile);

export const OUTPUT_WIDTH = 1920;
export const OUTPUT_HEIGHT = 1080;
export const PREVIEW_WIDTH = 1280;
export const PREVIEW_HEIGHT = 720;
export const DEFAULT_FPS = 30;
export const DEFAULT_LOUDNESS_LUFS = -14;
export const FONT_FILE = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf';
// A short, fixed crossfade length -- long enough to read as an
// intentional transition, short enough that clamping shot durations to
// the Step 9 3-8s granularity guidance always leaves room for it (see
// docs/architecture/visual-asset-pipeline.md#shot-granularity).
const TRANSITION_DURATION_SECONDS = 0.5;

async function ffmpeg(args, opts = {}) {
  return execFileAsync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { maxBuffer: 1024 * 1024 * 128, ...opts });
}

// drawtext's filter-graph mini-language treats `:`, `'`, `,`, `\`, `%`
// as syntactically meaningful -- these must be escaped even though the
// *outer* ffmpeg invocation is always argv-array (never a shell string),
// per docs/architecture/video-render-pipeline.md#ffmpeg-command-construction.
export function escapeDrawtext(text) {
  return String(text)
    .replace(/\\/g, '\\\\\\\\')
    .replace(/:/g, '\\:')
    .replace(/'/g, "’")
    .replace(/%/g, '\\%')
    .replace(/\n/g, ' ');
}

const XFADE_TRANSITIONS = { dissolve: 'dissolve', fade: 'fade', zoom: 'zoomin', match_cut: 'fade' };

export function isCutTransition(name) {
  return !name || name === 'cut' || name === 'none';
}

async function downloadAssetToFile(storagePath, destPath) {
  const buffer = await getObjectBuffer(storagePath);
  await writeFile(destPath, buffer);
  return destPath;
}

function motionFilter(motionPlan, durationSeconds, w, h) {
  const movement = (motionPlan && motionPlan.movement) || 'static';
  const fps = DEFAULT_FPS;
  const frames = Math.max(1, Math.round(durationSeconds * fps));
  // zoompan operates on an up-scaled source so the zoom/pan has room to
  // move without exposing empty edges -- 1.15x the target frame.
  const upW = Math.round(w * 1.15 / 2) * 2;
  const upH = Math.round(h * 1.15 / 2) * 2;
  const base = `scale=${upW}:${upH}:force_original_aspect_ratio=increase,crop=${upW}:${upH}`;
  const zoomStep = 0.15 / frames;
  switch (movement) {
    case 'slow_zoom_in':
    case 'zoom_in':
      return `${base},zoompan=z='min(zoom+${zoomStep.toFixed(6)},1.15)':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'zoom_out':
      return `${base},zoompan=z='if(eq(on,1),1.15,max(zoom-${zoomStep.toFixed(6)},1.0))':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'pan_left':
      return `${base},zoompan=z=1.15:x='max(0,(iw-iw/zoom)-((iw-iw/zoom)/${frames})*on)':y='(ih-ih/zoom)/2':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'pan_right':
      return `${base},zoompan=z=1.15:x='((iw-iw/zoom)/${frames})*on':y='(ih-ih/zoom)/2':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'pan_up':
      return `${base},zoompan=z=1.15:x='(iw-iw/zoom)/2':y='max(0,(ih-ih/zoom)-((ih-ih/zoom)/${frames})*on)':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'pan_down':
      return `${base},zoompan=z=1.15:x='(iw-iw/zoom)/2':y='((ih-ih/zoom)/${frames})*on':d=${frames}:s=${w}x${h}:fps=${fps}`;
    case 'static':
    default:
      return `scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}`;
  }
}

function cropScaleFilter(cropMode, w, h) {
  if (cropMode === 'contain') {
    // Letterbox/pillarbox onto a blurred, scaled copy of the same frame
    // -- never distorts the source, never a plain black bar unless the
    // channel explicitly wants that (a future render_policy option).
    return `split[bg][fg];[bg]scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h},gblur=sigma=20[bgblur];[fg]scale=${w}:${h}:force_original_aspect_ratio=decrease[fgscaled];[bgblur][fgscaled]overlay=(W-w)/2:(H-h)/2`;
  }
  // 'cover' (default): fill the frame, cropping any excess -- never
  // distorts aspect ratio.
  return `scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}`;
}

// Renders one scene to a silent (no audio track) clip of exactly its
// manifest duration, with motion (images) or trim (video), crop/scale,
// and a text overlay if the scene carries one. Charts/maps/text/brand
// scenes with no backing asset file (Step 9's spec-only asset types --
// see docs/architecture/video-render-pipeline.md#spec-only-assets)
// render as a styled brand-colored text card instead.
export async function prepareSceneClip(scene, { workDir, index, brandColors }) {
  const durationSeconds = scene.duration_ms / 1000;
  const outPath = join(workDir, `scene-${String(index).padStart(4, '0')}.mp4`);
  const isVideo = scene.asset_type === 'stock_video' || scene.asset_type === 'generated_video';

  if (!scene.asset_path) {
    // Spec-only scene (chart/map/text_animation/brand_asset/screenshot/
    // public_domain_archive with no acquired file) -- render the
    // overlay_text (or a placeholder) as a brand-colored text card. See
    // docs/architecture/video-render-pipeline.md#spec-only-assets for
    // why this is the deliberate Step 10 scope, not a missing feature.
    const bg = (brandColors && brandColors.primary) || '#1a1a1a';
    const text = escapeDrawtext(scene.overlay_text || scene.asset_type || 'Ancient History');
    await ffmpeg([
      '-f', 'lavfi', '-i', `color=c=${bg}:s=${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}:d=${durationSeconds}:r=${DEFAULT_FPS}`,
      '-vf', `drawtext=fontfile=${FONT_FILE}:text='${text}':x=(w-text_w)/2:y=(h-text_h)/2:fontsize=54:fontcolor=white:borderw=2:bordercolor=black@0.6`,
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-t', String(durationSeconds),
      outPath,
    ]);
    return outPath;
  }

  const localAsset = join(workDir, `asset-input-${index}${isVideo ? '.mp4' : '.img'}`);
  await downloadAssetToFile(scene.asset_path, localAsset);

  let vf;
  if (isVideo) {
    vf = cropScaleFilter(scene.crop_mode, OUTPUT_WIDTH, OUTPUT_HEIGHT);
  } else {
    vf = motionFilter(scene.motion_plan, durationSeconds, OUTPUT_WIDTH, OUTPUT_HEIGHT);
  }
  if (scene.overlay_text) {
    vf += `,drawtext=fontfile=${FONT_FILE}:text='${escapeDrawtext(scene.overlay_text)}':x=(w-text_w)/2:y=h-th-80:fontsize=42:fontcolor=white:borderw=2:bordercolor=black@0.6:box=1:boxcolor=black@0.35:boxborderw=12`;
  }

  const inputArgs = isVideo
    ? ['-stream_loop', '-1', '-i', localAsset]
    : ['-loop', '1', '-i', localAsset];

  await ffmpeg([
    ...inputArgs,
    '-vf', vf, '-an', '-r', String(DEFAULT_FPS),
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-t', String(durationSeconds),
    outPath,
  ]);
  return outPath;
}

// Chains prepared scene clips into one silent combined video: a plain
// concat for 'cut'/'none' transitions, an xfade crossfade (exact
// duration/offset math, so total timeline length is always predictable)
// for dissolve/fade/zoom/match_cut. See
// docs/architecture/video-render-pipeline.md#transitions.
export async function combineScenesWithTransitions(scenes, clipPaths, workDir) {
  if (clipPaths.length === 1) {
    return { path: clipPaths[0], durationSeconds: scenes[0].duration_ms / 1000 };
  }

  const inputArgs = [];
  clipPaths.forEach((p) => { inputArgs.push('-i', p); });

  const filterParts = [];
  // Normalize every input to a common timebase/framerate before any
  // concat/xfade -- mixing 'cut' (concat, which passes through each
  // input's own container timebase) and dissolve/fade/zoom (xfade,
  // which computes its own timebase from its duration parameter) in one
  // filter_complex chain otherwise fails with "First input link main
  // timebase does not match the corresponding second input link xfade
  // timebase" the moment a concat output feeds into a later xfade (a
  // real bug this step's own test suite caught during development).
  clipPaths.forEach((_, i) => { filterParts.push(`[${i}:v]fps=${DEFAULT_FPS},settb=AVTB[n${i}]`); });

  let currentLabel = 'n0';
  let cumulative = scenes[0].duration_ms / 1000;

  for (let i = 1; i < clipPaths.length; i += 1) {
    const nextLabel = `n${i}`;
    const outLabel = i === clipPaths.length - 1 ? 'vout' : `c${i}`;
    const transitionName = scenes[i].transition_in;
    const nextDuration = scenes[i].duration_ms / 1000;

    if (isCutTransition(transitionName)) {
      filterParts.push(`[${currentLabel}][${nextLabel}]concat=n=2:v=1:a=0[${outLabel}]`);
      cumulative += nextDuration;
    } else {
      const xfadeType = XFADE_TRANSITIONS[transitionName] || 'fade';
      const offset = Math.max(0, cumulative - TRANSITION_DURATION_SECONDS);
      filterParts.push(`[${currentLabel}][${nextLabel}]xfade=transition=${xfadeType}:duration=${TRANSITION_DURATION_SECONDS}:offset=${offset.toFixed(3)}[${outLabel}]`);
      cumulative = cumulative - TRANSITION_DURATION_SECONDS + nextDuration;
    }
    currentLabel = outLabel;
  }

  const outPath = join(workDir, 'combined.mp4');
  await ffmpeg([
    ...inputArgs,
    '-filter_complex', filterParts.join(';'),
    '-map', '[vout]',
    '-c:v', 'libx264', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-r', String(DEFAULT_FPS),
    outPath,
  ]);
  return { path: outPath, durationSeconds: cumulative };
}

export async function burnInSubtitles(videoPath, srtStoragePath, workDir) {
  if (!srtStoragePath) return videoPath;
  const localSrt = join(workDir, 'subtitles.srt');
  await downloadAssetToFile(srtStoragePath, localSrt);
  const outPath = join(workDir, 'captioned.mp4');
  await ffmpeg(['-i', videoPath, '-vf', `subtitles=${localSrt}`, '-c:a', 'copy', outPath]);
  return outPath;
}

// Prepares the final mixed/mastered audio: narration alone, or
// narration + background music ducked beneath it via sidechain
// compression, loudness-normalized to the channel's configured target.
// See docs/architecture/video-render-pipeline.md#audio-pipeline.
export async function prepareFinalAudio({ narrationPath, musicPath, loudnessTargetLufs, workDir }) {
  const localNarration = join(workDir, 'narration-input.audio');
  await downloadAssetToFile(narrationPath, localNarration);

  let mixedPath = localNarration;
  if (musicPath) {
    const localMusic = join(workDir, 'music-input.audio');
    await downloadAssetToFile(musicPath, localMusic);
    mixedPath = join(workDir, 'mixed.wav');
    // Sidechain-compress the music against the narration so it ducks
    // under speech automatically -- deterministic, no manual keyframing.
    await ffmpeg([
      '-i', localMusic, '-i', localNarration,
      '-filter_complex',
      '[0:a]aloop=loop=-1:size=2e9,volume=0.35[music];[music][1:a]sidechaincompress=threshold=0.05:ratio=8:attack=5:release=300[ducked];[ducked][1:a]amix=inputs=2:duration=first:weights=1 1[mixout]',
      '-map', '[mixout]',
      mixedPath,
    ]);
  }

  const normalizedPath = join(workDir, 'final-audio.wav');
  await ffmpeg(['-i', mixedPath, '-af', `loudnorm=I=${loudnessTargetLufs}:TP=-1.5:LRA=11`, '-ar', '48000', normalizedPath]);
  return normalizedPath;
}

export async function finalMux({ videoPath, audioPath, outputPath, crf = 20, preset = 'medium', width, height }) {
  const args = [
    '-i', videoPath, '-i', audioPath,
    '-map', '0:v', '-map', '1:a',
    '-c:v', 'libx264', '-crf', String(crf), '-preset', preset, '-pix_fmt', 'yuv420p',
  ];
  if (width && height) args.push('-vf', `scale=${width}:${height}`);
  args.push('-c:a', 'aac', '-ar', '48000', '-b:a', '192k', '-movflags', '+faststart', '-shortest', outputPath);
  await ffmpeg(args);
}

async function ffprobeFull(filePath) {
  const { stdout } = await execFileAsync('ffprobe', [
    '-v', 'error', '-print_format', 'json',
    '-show_entries', 'stream=codec_name,codec_type,width,height,r_frame_rate,sample_rate:format=duration,size',
    filePath,
  ], { maxBuffer: 1024 * 1024 * 16 });
  return JSON.parse(stdout);
}

// The full deterministic media-analysis payload render_quality_control()
// consumes -- ffprobe codec/resolution/duration facts, a decode-integrity
// pass, loudness, and black-frame detection. Never an LLM judgment of
// render quality, per the Step 10 brief.
export async function analyzeRenderOutput(filePath, { expectedWidth, expectedHeight } = {}) {
  const info = await ffprobeFull(filePath);
  const videoStream = (info.streams || []).find((s) => s.codec_type === 'video');
  const audioStream = (info.streams || []).find((s) => s.codec_type === 'audio');
  const durationSeconds = info.format && info.format.duration ? Number(info.format.duration) : null;

  let decodeOk = true;
  try {
    await execFileAsync('ffmpeg', ['-v', 'error', '-i', filePath, '-f', 'null', '-'], { maxBuffer: 1024 * 1024 * 16 });
  } catch {
    decodeOk = false;
  }

  let fps = null;
  if (videoStream && videoStream.r_frame_rate) {
    const [num, den] = videoStream.r_frame_rate.split('/').map(Number);
    fps = den ? Math.round((num / den) * 1000) / 1000 : num;
  }

  let integratedLufs = null;
  try {
    const result = await execFileAsync('ffmpeg', ['-i', filePath, '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json', '-f', 'null', '-'], { maxBuffer: 1024 * 1024 * 16 });
    const match = (result.stderr || '').match(/\{[^{}]*"input_i"[^{}]*\}/);
    if (match) integratedLufs = Number(JSON.parse(match[0]).input_i);
  } catch { /* leave null -- QC treats a missing value conservatively */ }

  let blackEvents = 0;
  try {
    await execFileAsync('ffmpeg', ['-i', filePath, '-vf', 'blackdetect=d=1.5:pic_th=0.98', '-an', '-f', 'null', '-'], { maxBuffer: 1024 * 1024 * 16 });
  } catch (err) {
    blackEvents = ((err.stderr || '').match(/black_start/g) || []).length;
  }

  return {
    has_video_stream: Boolean(videoStream),
    has_audio_stream: Boolean(audioStream),
    video_codec: videoStream ? videoStream.codec_name : null,
    audio_codec: audioStream ? audioStream.codec_name : null,
    width: videoStream ? Number(videoStream.width) : null,
    height: videoStream ? Number(videoStream.height) : null,
    fps,
    audio_sample_rate: audioStream ? Number(audioStream.sample_rate) : null,
    duration_seconds: durationSeconds,
    decode_ok: decodeOk,
    integrated_lufs: integratedLufs,
    excessive_black_events: blackEvents,
    file_size_bytes: info.format && info.format.size ? Number(info.format.size) : null,
    resolution_matches: expectedWidth && expectedHeight ? (videoStream && Number(videoStream.width) === expectedWidth && Number(videoStream.height) === expectedHeight) : null,
  };
}

export { sha256, fileSizeBytes, probe, join, putObject, getObjectBuffer, readFile };
