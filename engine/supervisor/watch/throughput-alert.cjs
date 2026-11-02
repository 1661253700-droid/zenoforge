#!/usr/bin/env node
'use strict';

const fs = require('fs');

const [unitsPath, logPath, pausePath, nowArg, stuckMinutesArg, noOutputHoursArg] = process.argv.slice(2);
const now = Number(nowArg);
const threshold = (raw, fallback) => {
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
};
const stuckMinutes = threshold(stuckMinutesArg, 60);
const noOutputHours = threshold(noOutputHoursArg, 3);

if (!unitsPath || !logPath || !pausePath || !Number.isFinite(now) || fs.existsSync(pausePath)) process.exit(0);

let ledger;
try {
  ledger = JSON.parse(fs.readFileSync(unitsPath, 'utf8'));
} catch {
  process.exit(0);
}
if (!ledger || !Array.isArray(ledger.units)) process.exit(0);

let log = '';
try { log = fs.readFileSync(logPath, 'utf8'); } catch {}
const lines = log.split(/\r?\n/);
const latestSkip = new Map();
const mergedAt = [];
for (const line of lines) {
  const skip = line.match(/merge skipped PR#(\d+)\s+\((.*)\)(?:\s|$)/);
  if (skip) latestSkip.set(skip[1], skip[2]);
  if (!/\bmerged PR#\d+\b/.test(line)) continue;
  const stamp = line.match(/^\[([^\]]+)\]/);
  if (!stamp) continue;
  const time = Date.parse(stamp[1]);
  if (Number.isFinite(time)) mergedAt.push(time / 1000);
}

const historyEpoch = unit => {
  if (!Array.isArray(unit.history)) return null;
  const dated = unit.history.filter(entry => entry && typeof entry.at === 'string' && Number.isFinite(Date.parse(entry.at)));
  if (!dated.length) return null;
  return Date.parse(dated[dated.length - 1].at) / 1000;
};
const prNumber = unit => {
  if (Number.isInteger(unit.pr) && unit.pr > 0) return String(unit.pr);
  if (typeof unit.pr === 'string' && /^[1-9]\d*$/.test(unit.pr)) return unit.pr;
  const match = typeof unit.id === 'string' && unit.id.match(/^pr-(\d+)$/);
  return match ? match[1] : null;
};
const ready = ledger.units.filter(unit => unit && unit.stage === 'ready-to-merge');
const pipelineReady = ready.filter(unit => unit.supervisor_owned !== true);
const recentMerge = seconds => mergedAt.some(time => time >= now - seconds && time <= now);
const stuck = pipelineReady.map(unit => ({unit, at: historyEpoch(unit), pr: prNumber(unit)}))
  .filter(entry => entry.at !== null && now - entry.at > stuckMinutes * 60)
  .sort((a, b) => a.at - b.at);

if (stuck.length && !recentMerge(stuckMinutes * 60)) {
  const oldest = stuck.slice(0, 5).map(({unit, pr}) => {
    const id = pr ? `PR#${pr}` : `unit ${unit.id || 'unknown'}`;
    const reason = pr ? latestSkip.get(pr) : null;
    return `${id} (${reason || 'no merge skipped reason recorded'})`;
  });
  process.stdout.write(`throughput stalled: ready-to-merge=${stuck.length} oldest=${oldest.join(', ')}\n`);
  process.exit(0);
}

if (ready.length && !recentMerge(noOutputHours * 3600)) {
  process.stdout.write(`throughput idle: ready-to-merge=${ready.length}, no merged PR# in ${noOutputHours}h\n`);
}
