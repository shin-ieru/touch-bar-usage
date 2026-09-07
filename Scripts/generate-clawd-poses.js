#!/usr/bin/env node
/*
 * Build-time generator for Clawd pose grids.
 *
 * Clawd is Anthropic's character and the upstream pose library publishes no
 * licence, so none of that artwork is committed to this repository. This script
 * fetches it onto the developer's own machine and writes a generated grid file
 * into a gitignored directory. See docs/branding.md.
 *
 * The fetched pose files are JavaScript that builds 20x20 grids from helpers.
 * They are evaluated inside a `vm` context that exposes only a bare `window`
 * object — no `require`, no `process`, no filesystem — so build-time evaluation
 * of third-party code cannot reach the rest of the machine.
 */
'use strict';

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const BASE = process.env.CLAWD_SOURCE || 'https://claudepix.vercel.app';
const OUT = process.argv[2] || 'GeneratedAssets/Clawd/clawd-poses.json';
const GRID = 20;

/* Which upstream frame becomes which severity pose. Frame indices are checked
 * before use; anything missing degrades to the base creature rather than
 * failing the build. */
const POSE_PLAN = [
  { pose: 'calm',    file: null,                        frame: null },
  { pose: 'alert',   file: 'expression_wink.html',      frame: 'first' },
  { pose: 'worried', file: 'expression_surprise.html',  frame: 2 },
  { pose: 'panic',   file: 'expression_surprise.html',  frame: 5 },
];

async function get(url) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.text();
}

/* Colours are read out of the upstream source rather than written into this
 * repository, for the same reason the grids are: they are part of the character
 * as drawn upstream. If extraction fails the app renders a tinted template
 * instead, which still reads correctly. */
function extractColors(source) {
  const body = source.match(/color\s*=\s*'(#[0-9a-fA-F]{3,8})'/);
  const eye = source.match(/v\s*===\s*EYE[\s\S]{0,160}?background\s*=\s*'(#[0-9a-fA-F]{3,8})'/);
  return {
    bodyColor: body ? body[1] : null,
    eyeColor: eye ? eye[1] : null,
  };
}

/** Runs the engine in a sandbox and returns its exported helpers. */
function loadEngine(source) {
  const sandbox = { window: {} };
  vm.createContext(sandbox);
  new vm.Script(source, { filename: 'creature-engine.js' }).runInContext(sandbox);
  const engine = sandbox.window.PixelEngine;
  if (!engine || !Array.isArray(engine.CREATURE)) {
    throw new Error('engine did not expose PixelEngine.CREATURE');
  }
  return { engine, sandbox };
}

/** Extracts the inline pose script from an animation page and evaluates it. */
function loadPreset(html, engine) {
  // The pose logic is the inline <script> without a src attribute.
  const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]);
  if (!blocks.length) throw new Error('no inline pose script found');
  // Drop the mount call: it needs a DOM we deliberately do not provide.
  const code = blocks[blocks.length - 1]
    .replace(/window\.PixelEngine\.mount\([\s\S]*?\);/g, '')
    .replace(/document\.[A-Za-z]+\([^)]*\)/g, 'null');

  const sandbox = { window: { PixelEngine: engine } };
  vm.createContext(sandbox);
  new vm.Script(code, { filename: 'pose.js' }).runInContext(sandbox);
  const preset = sandbox.window.PRESET;
  if (!preset || !Array.isArray(preset.frames)) throw new Error('no PRESET.frames');
  return preset;
}

function validGrid(grid) {
  return Array.isArray(grid)
    && grid.length === GRID
    && grid.every((row) => Array.isArray(row) && row.length === GRID
      && row.every((v) => v === 0 || v === 1 || v === 2));
}

/** Picks a frame from a preset, resolving `null` frames to the base creature. */
function selectFrame(preset, selector, base) {
  const frames = preset.frames;
  let entry;
  if (selector === 'first') {
    entry = frames.find((f) => f && f.frame);
  } else if (typeof selector === 'number') {
    entry = frames[selector];
  }
  const grid = entry && entry.frame ? entry.frame : base;
  return validGrid(grid) ? grid : base;
}

(async function main() {
  const engineSrc = await get(`${BASE}/animations/creature-engine.js?v=2`);
  const { engine } = loadEngine(engineSrc);
  const base = engine.CREATURE;
  if (!validGrid(base)) throw new Error('base creature grid failed validation');

  const cache = new Map();
  const poses = {};

  for (const plan of POSE_PLAN) {
    if (!plan.file) {
      poses[plan.pose] = base;
      continue;
    }
    try {
      if (!cache.has(plan.file)) {
        cache.set(plan.file, loadPreset(await get(`${BASE}/animations/${plan.file}`), engine));
      }
      poses[plan.pose] = selectFrame(cache.get(plan.file), plan.frame, base);
    } catch (error) {
      // A single missing pose must not fail the whole generation.
      process.stderr.write(`  note: ${plan.pose} fell back to base (${error.message})\n`);
      poses[plan.pose] = base;
    }
  }

  for (const [name, grid] of Object.entries(poses)) {
    if (!validGrid(grid)) throw new Error(`pose ${name} failed validation`);
  }

  const colors = extractColors(engineSrc);
  if (!colors.bodyColor) {
    process.stderr.write('  note: body colour not found; a tinted template will be used\n');
  }

  const payload = {
    source: BASE,
    generatedAt: new Date().toISOString(),
    gridSize: GRID,
    legend: { empty: 0, body: 1, eye: 2 },
    note: 'Generated locally. Not redistributable - see docs/branding.md.',
    ...colors,
    poses,
  };

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(payload, null, 2));
  process.stdout.write(`  wrote ${OUT} (${Object.keys(poses).length} poses)\n`);
})().catch((error) => {
  process.stderr.write(`clawd pose generation failed: ${error.message}\n`);
  process.exit(1);
});
