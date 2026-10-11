// Status page for dropbox-docker. Polls the JSON API and renders it.
"use strict";

const REFRESH_MS = 5000;

const STATES = {
  "up to date": ["Up to date", "ok"],
  "syncing": ["Syncing", "busy"],
  "indexing": ["Indexing", "busy"],
  "starting": ["Starting", "busy"],
  "sync_error": ["Sync error", "warn"],
  "not running": ["Not running", "bad"],
  "unknown": ["Waiting for Dropbox", "warn"],
};

let lastUpdate = null;

function $(id) {
  return document.getElementById(id);
}

function setText(id, text) {
  $(id).textContent = text;
}

function formatDuration(seconds) {
  if (seconds == null) return "–";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function formatAgo(epochSeconds) {
  if (!epochSeconds) return "Not yet";
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - epochSeconds));
  return seconds < 60 ? "Just now" : `${formatDuration(seconds)} ago`;
}

function render(data) {
  let [label, tone] = STATES[data.status] || [data.status, "warn"];
  if (!data.healthy) {
    [label, tone] = ["Not running", "bad"];
  } else if (!data.account.linked) {
    [label, tone] = ["Not linked", "warn"];
  }
  const pill = $("state");
  pill.textContent = label;
  pill.className = `pill ${tone}`;

  setText("raw", data.raw_status || "");
  $("link-hint").hidden = !data.healthy || data.account.linked;
  $("error").hidden = !data.last_error;
  setText("error", data.last_error ? `Last error: ${data.last_error}` : "");

  setText("syncing", data.sync.syncing.toLocaleString());
  setText("downloading", data.sync.downloading.toLocaleString());
  setText("uploading", data.sync.uploading.toLocaleString());

  setText("account", data.account.linked ? "Linked" : "Not linked");
  setText("last-sync", formatAgo(data.last_sync));
  setText("excluded", data.excluded_folders.length ? data.excluded_folders.join(", ") : "None");
  setText("version", data.daemon.version || "–");
  setText("memory", data.daemon.memory_mb != null ? `${Math.round(data.daemon.memory_mb)} MB` : "–");
  setText("restarts", data.daemon.restart_count);
  setText("uptime", formatDuration(data.daemon.uptime_seconds));

  const image = data.image || {};
  const revision = image.revision ? ` (${image.revision.slice(0, 7)})` : "";
  setText("image", `${image.version || "dev"}${revision}`);
}

async function refresh() {
  try {
    const response = await fetch("status", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
    lastUpdate = Date.now();
    $("offline").hidden = true;
  } catch (err) {
    $("offline").hidden = false;
  }
  setText("updated", lastUpdate ? `Updated ${new Date(lastUpdate).toLocaleTimeString()}` : "");
}

refresh();
setInterval(refresh, REFRESH_MS);
