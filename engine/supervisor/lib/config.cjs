const fs = require('fs');
const os = require('os');
const path = require('path');
const expand = p => p === '~' ? os.homedir() : p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
const file = expand(process.env.ZF_SUPERVISOR_CONFIG || '~/.zenoforge/supervisor/config.json');
let config;
try { config = JSON.parse(fs.readFileSync(file, 'utf8')); }
catch (error) { process.stderr.write(`zenoforge supervisor: config unavailable: ${file} (${error.message.replace(/\s*\n\s*/g, ' ')})\n`); process.exit(1); }
const watchDefaults = {
  ready_stuck_minutes: 60,
  no_output_hours: 3,
};
const watch = {
  ...watchDefaults,
  ...(config.watch && typeof config.watch === 'object' && !Array.isArray(config.watch) ? config.watch : {}),
};
for (const [key, fallback] of Object.entries(watchDefaults)) {
  const raw = watch[key];
  const value = typeof raw === 'number' || (typeof raw === 'string' && raw.trim() !== '') ? Number(raw) : NaN;
  watch[key] = Number.isFinite(value) && value >= 0 ? value : fallback;
}
config.watch = watch;
module.exports = { config, expand };
