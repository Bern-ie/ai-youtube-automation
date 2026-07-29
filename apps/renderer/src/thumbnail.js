// Thumbnail composition engine for the publication package pipeline
// (Step 11). All composition is done with FFmpeg -- no sharp/libvips or
// other new native dependency -- reusing the identical binary Steps
// 8/9/10 already validated on both AMD64 and ARM64. See
// docs/architecture/publication-package-pipeline.md#thumbnail-rendering.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { getObjectBuffer } from './storage.js';
import { sha256, fileSizeBytes, withTempDir } from './audio.js';
import { writeBufferToFile } from './visual.js';
import { escapeDrawtext, FONT_FILE } from './render.js';

const execFileAsync = promisify(execFile);

export const THUMBNAIL_WIDTH = 1280;
export const THUMBNAIL_HEIGHT = 720;
const MAX_RECOMMENDED_OVERLAY_WORDS = 5;
const MAX_OVERLAY_WORDS_HARD = 8;

async function ffmpeg(args) {
  return execFileAsync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { maxBuffer: 1024 * 1024 * 64 });
}

async function downloadToFile(storagePath, destPath) {
  const buffer = await getObjectBuffer(storagePath);
  await writeBufferToFile(destPath, buffer);
  return destPath;
}

// Extracts one frame from the approved final video at the given
// timestamp -- the "extracted final-video frame + typography" thumbnail
// strategy. Uses `-ss` before `-i` for fast keyframe-seeked extraction
// (acceptable for a thumbnail candidate, not a frame-accurate edit).
export async function extractFinalVideoFrame(finalVideoStoragePath, timestampMs, workDir) {
  const localVideo = join(workDir, 'source-video.mp4');
  await downloadToFile(finalVideoStoragePath, localVideo);
  const framePath = join(workDir, 'extracted-frame.png');
  const seconds = Math.max(0, timestampMs / 1000);
  await ffmpeg(['-ss', String(seconds), '-i', localVideo, '-vframes', '1', framePath]);
  return framePath;
}

function coverScaleCropFilter(w = THUMBNAIL_WIDTH, h = THUMBNAIL_HEIGHT) {
  return `scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}`;
}

function overlayTextFilter(text) {
  const escaped = escapeDrawtext(text);
  return `drawtext=fontfile=${FONT_FILE}:text='${escaped}':x=(w-text_w)/2:y=h-th-60:fontsize=64:fontcolor=white:borderw=4:bordercolor=black@0.7:box=1:boxcolor=black@0.4:boxborderw=20`;
}

export function overlayWordCount(text) {
  if (!text) return 0;
  return String(text).trim().split(/\s+/).filter(Boolean).length;
}

// Composes one thumbnail image from a resolved concept. `sourceLocalPath`
// is a locally-downloaded source image/frame (for existing_asset/
// video_frame/composite strategies), or null for brand_template (and
// for generated_image, where the caller already has raw provider bytes
// -- see composeFromGeneratedBytes below). `secondaryLocalPath` is an
// optional second image for the 'composite' strategy (inset in a corner).
export async function composeThumbnail({ sourceLocalPath, secondaryLocalPath, overlayText, brandColor, logoLocalPath }, workDir) {
  const outPath = join(workDir, 'thumbnail.jpg');
  const bg = brandColor || '#1a1a1a';
  const vfParts = [];
  const inputArgs = [];

  if (sourceLocalPath) {
    inputArgs.push('-i', sourceLocalPath);
    vfParts.push(`[0:v]${coverScaleCropFilter()}[base]`);
  } else {
    inputArgs.push('-f', 'lavfi', '-i', `color=c=${bg}:s=${THUMBNAIL_WIDTH}x${THUMBNAIL_HEIGHT}:d=1:r=1`);
    vfParts.push('[0:v]null[base]');
  }

  let currentLabel = 'base';
  if (secondaryLocalPath) {
    inputArgs.push('-i', secondaryLocalPath);
    vfParts.push(`[1:v]scale=${Math.round(THUMBNAIL_WIDTH * 0.35)}:-1[inset]`);
    vfParts.push(`[${currentLabel}][inset]overlay=W-w-30:H-h-30[withinset]`);
    currentLabel = 'withinset';
  }

  const logoInputIndex = inputArgs.filter((a) => a === '-i').length;
  if (logoLocalPath) {
    inputArgs.push('-i', logoLocalPath);
    vfParts.push(`[${logoInputIndex}:v]scale=160:-1[logo]`);
    vfParts.push(`[${currentLabel}][logo]overlay=30:30[withlogo]`);
    currentLabel = 'withlogo';
  }

  if (overlayText) {
    vfParts.push(`[${currentLabel}]${overlayTextFilter(overlayText)}[withtext]`);
    currentLabel = 'withtext';
  }

  vfParts.push(`[${currentLabel}]format=yuvj420p[out]`);

  await ffmpeg([
    ...inputArgs,
    '-filter_complex', vfParts.join(';'),
    '-map', '[out]',
    '-frames:v', '1',
    '-q:v', '2',
    outPath,
  ]);
  return outPath;
}

// The 'generated_image' strategy: the OpenAI Images call already ran in
// n8n (reusing the exact same provider adapter Step 9 uses -- see
// docs/architecture/publication-package-pipeline.md#generated-thumbnail-imagery);
// this just crops/scales the raw bytes to the exact 16:9 thumbnail frame
// and applies the same optional text/logo overlay pipeline.
export async function composeFromGeneratedBytes(rawImageBuffer, { overlayText, logoLocalPath }, workDir) {
  const rawPath = join(workDir, 'generated-raw.png');
  await writeBufferToFile(rawPath, rawImageBuffer);
  return composeThumbnail({ sourceLocalPath: rawPath, overlayText, logoLocalPath }, workDir);
}

async function ffprobeJson(filePath) {
  const { stdout } = await execFileAsync('ffprobe', [
    '-v', 'error', '-print_format', 'json',
    '-show_entries', 'stream=codec_name,codec_type,width,height:format=size',
    filePath,
  ], { maxBuffer: 1024 * 1024 * 16 });
  return JSON.parse(stdout);
}

// Deterministic thumbnail QC facts -- dimensions, decodability, and a
// simple luma-range contrast proxy (never a claimed CTR/engagement
// prediction, per the brief). `signalstats` reports per-frame min/max
// luma on stderr; a very small range flags a likely blank/flat image.
async function measureContrastRange(filePath) {
  try {
    // The `metadata=print` filter logs each frame's stats via av_log at
    // INFO level -- this must run without the `-loglevel error` every
    // other ffmpeg call in this module uses (the shared ffmpeg() helper
    // above), or the output this function greps for is silently
    // suppressed and never appears on stderr at all.
    const { stderr } = await execFileAsync('ffmpeg', [
      '-loglevel', 'info', '-i', filePath, '-vf', 'signalstats,metadata=print', '-f', 'null', '-',
    ], { maxBuffer: 1024 * 1024 * 16 });
    const yminMatch = stderr.match(/lavfi\.signalstats\.YMIN=(\d+)/);
    const ymaxMatch = stderr.match(/lavfi\.signalstats\.YMAX=(\d+)/);
    if (!yminMatch || !ymaxMatch) return null;
    return Number(ymaxMatch[1]) - Number(yminMatch[1]);
  } catch {
    return null;
  }
}

export async function validateThumbnailFile(filePath, { expectedWidth = THUMBNAIL_WIDTH, expectedHeight = THUMBNAIL_HEIGHT, overlayText } = {}) {
  const info = await ffprobeJson(filePath);
  const stream = (info.streams || []).find((s) => s.codec_type === 'video');
  const width = stream ? Number(stream.width) : null;
  const height = stream ? Number(stream.height) : null;

  let decodeOk = true;
  try {
    await execFileAsync('ffmpeg', ['-v', 'error', '-i', filePath, '-f', 'null', '-'], { maxBuffer: 1024 * 1024 * 16 });
  } catch {
    decodeOk = false;
  }

  const contrastRange = await measureContrastRange(filePath);
  const wordCount = overlayWordCount(overlayText);

  return {
    width_px: width,
    height_px: height,
    aspect_ratio_matches: Boolean(width && height && Math.abs(width / height - 16 / 9) < 0.02),
    dimensions_match_expected: width === expectedWidth && height === expectedHeight,
    format_name: stream ? stream.codec_name : null,
    decode_ok: decodeOk,
    file_size_bytes: fileSizeBytes(filePath),
    contrast_range: contrastRange,
    low_contrast: contrastRange !== null && contrastRange < 20,
    overlay_word_count: wordCount,
    excessive_text: wordCount > MAX_OVERLAY_WORDS_HARD,
    text_over_recommended: wordCount > MAX_RECOMMENDED_OVERLAY_WORDS,
  };
}

export { sha256, fileSizeBytes, withTempDir, downloadToFile };
