const LEVELS = ['debug', 'info', 'warn', 'error'];
const MIN_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();
const SERVICE_NAME = process.env.SERVICE_NAME || 'unknown-service';

const SENSITIVE_KEYS = new Set([
  'apikey', 'api_key', 'authorization', 'password', 'secret',
  'token', 'credential', 'credentials', 'oauth',
  'accesstoken', 'access_token', 'refreshtoken', 'refresh_token',
]);

function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [key, v] of Object.entries(value)) {
      out[key] = SENSITIVE_KEYS.has(key.toLowerCase()) ? '[REDACTED]' : redact(v);
    }
    return out;
  }
  return value;
}

function write(level, message, fields = {}) {
  if (LEVELS.indexOf(level) < LEVELS.indexOf(MIN_LEVEL)) return;
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service: SERVICE_NAME,
    message,
    ...redact(fields),
  };
  const line = JSON.stringify(entry);
  if (level === 'error') {
    process.stderr.write(line + '\n');
  } else {
    process.stdout.write(line + '\n');
  }
}

export const logger = {
  debug: (message, fields) => write('debug', message, fields),
  info: (message, fields) => write('info', message, fields),
  warn: (message, fields) => write('warn', message, fields),
  error: (message, fields) => write('error', message, fields),
};
