// Generates tiny synthetic WAV (PCM16) buffers entirely in JS, with no
// external dependency (not even ffmpeg) and nothing committed to disk --
// per the Step 8 brief's "do not commit large audio files" constraint.
// The renderer still does the real work (ffprobe/silencedetect/loudnorm)
// on whatever bytes we send it; these just need to be valid, tiny audio.

function riffHeader(dataLength, sampleRate, numChannels = 1, bitsPerSample = 16) {
  const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
  const blockAlign = numChannels * (bitsPerSample / 8);
  const buf = Buffer.alloc(44);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataLength, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(numChannels, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(byteRate, 28);
  buf.writeUInt16LE(blockAlign, 32);
  buf.writeUInt16LE(bitsPerSample, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataLength, 40);
  return buf;
}

/** A pure sine tone at `freqHz`, `seconds` long -- a normal, valid "voiced" chunk. */
function makeToneWav(seconds, { sampleRate = 44100, freqHz = 220, amplitude = 0.4 } = {}) {
  const numSamples = Math.round(seconds * sampleRate);
  const data = Buffer.alloc(numSamples * 2);
  for (let i = 0; i < numSamples; i += 1) {
    const sample = Math.sin((2 * Math.PI * freqHz * i) / sampleRate) * amplitude;
    data.writeInt16LE(Math.round(sample * 32767), i * 2);
  }
  return Buffer.concat([riffHeader(data.length, sampleRate), data]);
}

/** Pure digital silence, `seconds` long. */
function makeSilentWav(seconds, { sampleRate = 44100 } = {}) {
  const numSamples = Math.round(seconds * sampleRate);
  const data = Buffer.alloc(numSamples * 2); // zeroed = silence
  return Buffer.concat([riffHeader(data.length, sampleRate), data]);
}

/** A short tone flanked by long silence -- exercises leading/trailing silence detection. */
function makeSilenceHeavyWav(totalSeconds, { sampleRate = 44100, voicedFraction = 0.05 } = {}) {
  const silenceEachSide = totalSeconds * ((1 - voicedFraction) / 2);
  const voiced = totalSeconds * voicedFraction;
  const parts = [
    makeSilentWav(silenceEachSide, { sampleRate }).subarray(44),
    makeToneWav(voiced, { sampleRate }).subarray(44),
    makeSilentWav(silenceEachSide, { sampleRate }).subarray(44),
  ];
  const data = Buffer.concat(parts);
  return Buffer.concat([riffHeader(data.length, sampleRate), data]);
}

/** Deliberately much shorter than any plausible chunk -- triggers the truncation heuristic. */
function makeTruncatedWav({ sampleRate = 44100 } = {}) {
  return makeToneWav(0.05, { sampleRate });
}

/** Not audio at all -- e.g. a TTS provider's JSON error body mistakenly forwarded as bytes. */
function makeInvalidAudioBuffer() {
  return Buffer.from(JSON.stringify({ error: 'not audio' }), 'utf8');
}

export { makeToneWav, makeSilentWav, makeSilenceHeavyWav, makeTruncatedWav, makeInvalidAudioBuffer };
