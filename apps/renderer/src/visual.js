// FFprobe-based visual asset validation and SSRF-guarded downloading for
// the visual asset pipeline (Step 9). Deliberately reuses ffprobe rather
// than adding a native image library (sharp/Canvas) — see
// docs/architecture/visual-asset-pipeline.md#image-processing: ffmpeg
// already decodes every still-image format this pipeline needs
// (JPEG/PNG/WebP) and every video container it needs (MP4/WebM/MOV), so
// a second native-dependency surface isn't justified yet.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lookup as dnsLookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const execFileAsync = promisify(execFile);

const MAX_DOWNLOAD_BYTES = Number(process.env.VISUAL_ASSET_MAX_BYTES || 100 * 1024 * 1024);
const DOWNLOAD_TIMEOUT_MS = Number(process.env.VISUAL_ASSET_DOWNLOAD_TIMEOUT_MS || 20_000);
const MAX_REDIRECTS = 3;

async function ffprobeJson(filePath) {
  const { stdout } = await execFileAsync('ffprobe', [
    '-v', 'error', '-print_format', 'json',
    '-show_entries', 'stream=codec_name,codec_type,width,height:format=duration,format_name',
    filePath,
  ], { maxBuffer: 1024 * 1024 * 64 });
  return JSON.parse(stdout);
}

// Probes an already-downloaded file and classifies it as image or video.
// Not a "does it launch" check — every caller must confirm a real
// decodable stream exists before persisting anything, per
// docs/architecture/visual-asset-pipeline.md#asset-qc.
export async function probeVisual(filePath) {
  const info = await ffprobeJson(filePath);
  const videoStream = (info.streams || []).find((s) => s.codec_type === 'video');
  const durationSeconds = info.format && info.format.duration ? Number(info.format.duration) : null;
  // A still image decodes as exactly one "video" stream in ffprobe's
  // model with no meaningful duration; a real video has a duration and
  // (usually) more than a handful of frames. Distinguish by duration
  // rather than codec name, since JPEG/PNG/WebP/MP4/WebM/MOV are all
  // "video" codec_type to ffprobe.
  const isVideo = durationSeconds !== null && durationSeconds > 0.15;
  return {
    hasVisualStream: Boolean(videoStream),
    isVideo,
    codec: videoStream ? videoStream.codec_name : null,
    widthPx: videoStream ? Number(videoStream.width) : null,
    heightPx: videoStream ? Number(videoStream.height) : null,
    durationSeconds: isVideo ? durationSeconds : null,
    formatName: info.format ? info.format.format_name : null,
  };
}

function isPrivateOrLinkLocalIp(ip) {
  const version = isIP(ip);
  if (version === 4) {
    const octets = ip.split('.').map(Number);
    return (
      octets[0] === 10
      || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31)
      || (octets[0] === 192 && octets[1] === 168)
      || octets[0] === 127
      || (octets[0] === 169 && octets[1] === 254)
      || octets[0] === 0
    );
  }
  if (version === 6) {
    const lower = ip.toLowerCase();
    return lower === '::1' || lower.startsWith('fc') || lower.startsWith('fd') || lower.startsWith('fe80');
  }
  return true; // unresolvable/unknown shape -- fail closed.
}

// Downloads a URL with the protections docs/architecture/visual-asset-pipeline.md#asset-download-security
// requires: HTTPS only (HTTP allowed only for explicit test fixtures via
// ALLOW_INSECURE_VISUAL_DOWNLOADS), DNS-resolved private/link-local IPs
// rejected before connecting, a byte-size cap enforced while streaming
// (not just after the fact), a timeout, and a bounded manual redirect
// count (never trusting fetch's automatic redirect to re-check the new
// host). Every URL reaching this function must already originate from a
// trusted, explicitly-configured provider's own API response -- this is
// defense in depth, not the only control (see
// docs/architecture/visual-asset-pipeline.md#asset-search).
export async function downloadWithGuards(url) {
  let current = url;
  for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
    const parsed = new URL(current);
    const allowInsecure = process.env.ALLOW_INSECURE_VISUAL_DOWNLOADS === '1';
    if (parsed.protocol !== 'https:' && !(allowInsecure && parsed.protocol === 'http:')) {
      throw new Error(`refusing non-HTTPS download URL: ${parsed.protocol}`);
    }
    if (!allowInsecure) {
      const { address } = await dnsLookup(parsed.hostname);
      if (isPrivateOrLinkLocalIp(address)) {
        throw new Error(`refusing download URL resolving to a private/link-local address: ${parsed.hostname} -> ${address}`);
      }
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DOWNLOAD_TIMEOUT_MS);
    let res;
    try {
      res = await fetch(current, { redirect: 'manual', signal: controller.signal });
    } finally {
      clearTimeout(timeout);
    }

    if ([301, 302, 303, 307, 308].includes(res.status)) {
      const location = res.headers.get('location');
      if (!location) throw new Error(`redirect response with no Location header (status ${res.status})`);
      current = new URL(location, current).toString();
      continue;
    }
    if (!res.ok) throw new Error(`download failed: HTTP ${res.status}`);

    const contentLength = Number(res.headers.get('content-length') || 0);
    if (contentLength > MAX_DOWNLOAD_BYTES) {
      throw new Error(`declared content-length ${contentLength} exceeds ${MAX_DOWNLOAD_BYTES} byte cap`);
    }

    const chunks = [];
    let total = 0;
    for await (const chunk of res.body) {
      total += chunk.length;
      if (total > MAX_DOWNLOAD_BYTES) throw new Error(`download exceeded ${MAX_DOWNLOAD_BYTES} byte cap mid-stream`);
      chunks.push(chunk);
    }
    return { buffer: Buffer.concat(chunks), contentType: res.headers.get('content-type') || null, finalUrl: current };
  }
  throw new Error(`exceeded ${MAX_REDIRECTS} redirects`);
}

export async function writeBufferToFile(filePath, buffer) {
  await writeFile(filePath, buffer);
}

export function visualAssetBasePath(channelId, contentProjectId) {
  return `channels/${channelId}/projects/${contentProjectId}/assets`;
}

export function assetSubdirFor(assetType) {
  const map = {
    stock_video: 'stock', stock_image: 'stock', generated_image: 'generated', generated_video: 'generated',
    screenshot: 'screenshots', chart: 'charts', map: 'maps', brand_asset: 'brand',
    motion_graphic: 'generated', text_animation: 'generated', public_domain_archive: 'archive',
  };
  return map[assetType] || 'stock';
}

export { join };
