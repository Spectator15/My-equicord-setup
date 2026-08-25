/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import { addContextMenuPatch, NavContextMenuPatchCallback, removeContextMenuPatch } from "@api/ContextMenu";
import { Divider } from "@components/Divider";
import definePlugin from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { ChannelStore, Constants, Menu, Modal, openModal, React, RestAPI, useState } from "@webpack/common";
import { strToU8, type Zippable, zipSync } from "fflate";

type ExportFormat = "json" | "onlineHtml" | "offlineArchive" | "singleHtml";
type AssetCategory = "attachments" | "avatars" | "emojis" | "stickers" | "embeds";
type MediaKind = "image" | "video" | "audio" | "file";
type HtmlMode = "online" | "archive" | "single";

interface ExportOptions {
    attachments: boolean;
    avatars: boolean;
    emojisStickers: boolean;
    embedMedia: boolean;
}

interface ExportProgress {
    stage: string;
    processed: number;
    total: number;
    downloadedBytes: number;
    failures: number;
}

interface AssetRequest {
    aliases: string[];
    category: AssetCategory;
    expectedSize: number;
    kind: MediaKind;
    originalUrl: string;
    path: string;
    urls: string[];
}

interface AssetCatalog {
    aliases: Map<string, AssetRequest>;
    requests: AssetRequest[];
}

interface AssetResult {
    bytes?: Uint8Array;
    contentType: string;
    error?: string;
    kind: MediaKind;
    originalUrl: string;
    path: string;
}

interface DownloadSummary {
    aliases: Map<string, AssetResult>;
    downloaded: AssetResult[];
    downloadedBytes: number;
    failures: AssetResult[];
}

interface ArchiveBuildResult {
    bytes: Uint8Array;
    html: string;
    manifest: Record<string, unknown>;
    report: string;
}

interface EmbeddedAssetPayload {
    aliases: Record<string, string>;
    data: Record<string, string>;
}

const DEFAULT_OPTIONS: ExportOptions = {
    attachments: true,
    avatars: true,
    emojisStickers: true,
    embedMedia: true
};
const ASSET_CONCURRENCY = 4;
const ASSET_RETRIES = 3;
const ASSET_TIMEOUT_MS = 20_000;
const SINGLE_HTML_WARNING_BYTES = 25 * 1024 * 1024;
const GROUP_WINDOW_MS = 7 * 60 * 1000;

const FORMAT_CHOICES: Array<{ id: ExportFormat; title: string; description: string; badge?: string; }> = [
    { id: "json", title: "JSON", description: "Raw data, preserving every collected message field." },
    { id: "onlineHtml", title: "Online HTML", description: "Small file; media loads from its original online source." },
    { id: "offlineArchive", title: "Offline Archive", description: "Complete offline copy in one ZIP file.", badge: "Recommended" },
    { id: "singleHtml", title: "Single HTML", description: "One portable offline file; potentially very large." }
];

const EXPORT_MODAL_CSS = `
.eq-export-modal { color: #dbdee1; padding: 4px 0; }
.eq-export-modal * { box-sizing: border-box; }
.eq-export-format-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.eq-export-format {
    appearance: none; min-height: 78px; padding: 12px; border: 1px solid #4e5058; border-radius: 7px;
    background: #2b2d31; color: #dbdee1; text-align: left; cursor: pointer;
}
.eq-export-format:hover:not(:disabled), .eq-export-format:focus-visible { border-color: #949ba4; outline: none; }
.eq-export-format--selected { border-color: #7289da; background: #35384a; box-shadow: inset 0 0 0 1px #7289da; }
.eq-export-format:disabled { cursor: not-allowed; opacity: .6; }
.eq-export-format-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; color: #f2f3f5; font-size: 14px; font-weight: 700; }
.eq-export-format-desc { display: block; margin-top: 5px; color: #b5bac1; font-size: 12px; line-height: 1.4; }
.eq-export-badge { padding: 2px 6px; border-radius: 4px; background: #248046; color: #fff; font-size: 10px; font-weight: 700; }
.eq-export-options { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px 14px; margin-top: 12px; padding: 11px 12px; border: 1px solid #3f4147; border-radius: 7px; background: #2b2d31; }
.eq-export-option { display: flex; align-items: center; gap: 8px; min-height: 28px; color: #dbdee1; font-size: 13px; cursor: pointer; }
.eq-export-option input { width: 16px; height: 16px; accent-color: #5865f2; }
.eq-export-summary, .eq-export-progress { margin-top: 12px; padding: 11px 12px; border: 1px solid #3f4147; border-radius: 7px; background: #232428; }
.eq-export-summary-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 7px; }
.eq-export-metric { color: #b5bac1; font-size: 11px; }
.eq-export-metric strong { display: block; margin-top: 2px; color: #f2f3f5; font-size: 14px; }
.eq-export-progress-line { display: flex; justify-content: space-between; gap: 10px; color: #b5bac1; font-size: 12px; }
.eq-export-bar { height: 5px; margin-top: 9px; overflow: hidden; border-radius: 3px; background: #3f4147; }
.eq-export-bar > span { display: block; height: 100%; background: #5865f2; transition: width .15s ease; }
.eq-export-note, .eq-export-status { margin-top: 10px; color: #b5bac1; font-size: 12px; line-height: 1.4; }
.eq-export-warning { color: #f0b232; }
.eq-export-actions { display: flex; gap: 9px; margin-top: 14px; }
.eq-export-button { appearance: none; min-height: 38px; padding: 0 15px; border: 1px solid transparent; border-radius: 6px; color: #fff; font-weight: 700; cursor: pointer; }
.eq-export-button--primary { flex: 1; background: #5865f2; border-color: #7289da; }
.eq-export-button--primary:hover:not(:disabled) { background: #4752c4; }
.eq-export-button--cancel { background: #4e5058; border-color: #6d6f78; }
.eq-export-button:disabled { cursor: not-allowed; opacity: .58; }
@media (max-width: 540px) {
    .eq-export-format-grid, .eq-export-options { grid-template-columns: 1fr; }
    .eq-export-summary-grid { grid-template-columns: 1fr 1fr; }
}
`;

function abortError(): DOMException {
    return new DOMException("Export cancelled.", "AbortError");
}

function throwIfAborted(signal: AbortSignal) {
    if (signal.aborted) throw abortError();
}

function isAbortError(error: unknown): boolean {
    return error instanceof DOMException && error.name === "AbortError";
}

function delay(ms: number, signal: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        const timer = window.setTimeout(() => {
            signal.removeEventListener("abort", onAbort);
            resolve();
        }, ms);
        const onAbort = () => {
            window.clearTimeout(timer);
            reject(abortError());
        };
        signal.addEventListener("abort", onAbort, { once: true });
    });
}

async function fetchAllMessages(channelId: string, signal: AbortSignal, onProgress: (count: number) => void) {
    const messages: any[] = [];
    let beforeId: string | null = null;

    while (true) {
        throwIfAborted(signal);
        const query: Record<string, string | number> = { limit: 100 };
        if (beforeId) query.before = beforeId;
        const response = await RestAPI.get({ url: Constants.Endpoints.MESSAGES(channelId), query });
        throwIfAborted(signal);
        const status = Number(response?.status ?? 200);
        if (response?.ok === false || status >= 400) throw new Error(`Discord returned ${status}.`);

        const batch: any[] = Array.isArray(response.body) ? response.body : [];
        if (!batch.length) break;
        messages.push(...batch);
        onProgress(messages.length);
        if (batch.length < 100) break;
        beforeId = batch[batch.length - 1].id;
        await delay(250, signal);
    }

    return messages.reverse();
}

const HTML_ESCAPE_MAP: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
};

function escapeHtml(value: unknown): string {
    return String(value ?? "").replace(/[&<>"']/g, character => HTML_ESCAPE_MAP[character] ?? character);
}

function safeExternalUrl(value: unknown): string {
    try {
        const url = new URL(String(value ?? ""));
        return url.protocol === "https:" || url.protocol === "http:" ? url.href : "";
    } catch {
        return "";
    }
}

function formatBytes(value: unknown): string {
    const bytes = Number(value);
    if (!Number.isFinite(bytes) || bytes < 0) return "Unknown";
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let index = 0;
    while (size >= 1024 && index < units.length - 1) {
        size /= 1024;
        index++;
    }
    return `${size >= 10 || index === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
}

function mediaKind(item: any): MediaKind {
    const contentType = String(item?.content_type ?? item?.contentType ?? "").toLowerCase();
    const name = String(item?.filename ?? item?.name ?? item?.url ?? "").toLowerCase();
    if (contentType.startsWith("image/") || /\.(?:apng|avif|bmp|gif|jpe?g|png|svg|webp)(?:$|[?#])/.test(name)) return "image";
    if (contentType.startsWith("video/") || /\.(?:m4v|mov|mp4|ogv|webm)(?:$|[?#])/.test(name)) return "video";
    if (contentType.startsWith("audio/") || /\.(?:aac|flac|m4a|mp3|oga|ogg|opus|wav|weba)(?:$|[?#])/.test(name)) return "audio";
    return "file";
}

function sanitizeFilenamePart(value: unknown, fallback = "asset"): string {
    const cleaned = String(value ?? "")
        .normalize("NFKC")
        .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
        .replace(/\.\.+/g, ".")
        .replace(/\s+/g, " ")
        .replace(/^[. ]+|[. ]+$/g, "")
        .slice(0, 96);
    return cleaned || fallback;
}

function safeFilename(value: string): string {
    return sanitizeFilenamePart(value, "discord-export");
}

function extensionFrom(value: unknown, kind: MediaKind): string {
    const plain = String(value ?? "").split(/[?#]/, 1)[0];
    const match = plain.match(/\.([A-Za-z0-9]{1,8})$/);
    if (match) return `.${match[1].toLowerCase()}`;
    if (kind === "image") return ".webp";
    if (kind === "video") return ".mp4";
    if (kind === "audio") return ".ogg";
    return ".bin";
}

function uniqueAssetPath(category: AssetCategory, id: string, originalName: string, kind: MediaKind, used: Set<string>): string {
    const safeId = sanitizeFilenamePart(id, "asset");
    let safeName = sanitizeFilenamePart(originalName, "asset");
    if (!/\.[A-Za-z0-9]{1,8}$/.test(safeName)) safeName += extensionFrom(originalName, kind);
    const dot = safeName.lastIndexOf(".");
    const stem = dot > 0 ? safeName.slice(0, dot) : safeName;
    const extension = dot > 0 ? safeName.slice(dot).toLowerCase() : extensionFrom(originalName, kind);
    let path = `assets/${category}/${safeId}-${stem}${extension}`;
    let suffix = 2;
    while (used.has(path.toLowerCase())) path = `assets/${category}/${safeId}-${stem}-${suffix++}${extension}`;
    used.add(path.toLowerCase());
    return path;
}

function stickerItems(message: any): any[] {
    return Array.isArray(message?.sticker_items)
        ? message.sticker_items
        : Array.isArray(message?.stickers) ? message.stickers : [];
}

function collectAssetRequests(messages: any[], options: ExportOptions): AssetCatalog {
    const aliases = new Map<string, AssetRequest>();
    const byUrl = new Map<string, AssetRequest>();
    const requests: AssetRequest[] = [];
    const usedPaths = new Set<string>();

    function add(alias: string, category: AssetCategory, id: string, originalName: string, urls: unknown[], kind: MediaKind, expectedSize = 0) {
        const safeUrls = urls.map(safeExternalUrl).filter(Boolean);
        if (!safeUrls.length) return;
        const dedupeKey = safeUrls[0];
        let request = byUrl.get(dedupeKey);
        if (!request) {
            request = {
                aliases: [],
                category,
                expectedSize: Number.isFinite(expectedSize) && expectedSize > 0 ? expectedSize : 0,
                kind,
                originalUrl: safeUrls[0],
                path: uniqueAssetPath(category, id, originalName, kind, usedPaths),
                urls: Array.from(new Set(safeUrls))
            };
            requests.push(request);
            byUrl.set(dedupeKey, request);
        }
        if (!aliases.has(alias)) request.aliases.push(alias);
        aliases.set(alias, request);
    }

    for (const message of messages) {
        const messageId = sanitizeFilenamePart(message?.id, "message");
        const author = message?.author;
        if (options.avatars && author?.id && author?.avatar) {
            const animated = String(author.avatar).startsWith("a_");
            const extension = animated ? "gif" : "webp";
            add(
                `avatar:${author.id}:${author.avatar}`,
                "avatars",
                `${author.id}-${author.avatar}`,
                `avatar.${extension}`,
                [`https://cdn.discordapp.com/avatars/${author.id}/${author.avatar}.${extension}?size=128`],
                "image"
            );
        }

        if (options.attachments) {
            const attachments = Array.isArray(message?.attachments) ? message.attachments : [];
            attachments.forEach((attachment: any, index: number) => {
                const id = String(attachment?.id ?? index);
                add(
                    `attachment:${message?.id}:${id}`,
                    "attachments",
                    `${messageId}-${sanitizeFilenamePart(id, String(index))}`,
                    String(attachment?.filename ?? `attachment-${index}`),
                    [attachment?.url, attachment?.proxy_url],
                    mediaKind(attachment),
                    Number(attachment?.size ?? 0)
                );
            });
        }

        if (options.emojisStickers) {
            const emojiPattern = /<(a?):([A-Za-z0-9_]+):(\d+)>/g;
            for (const match of String(message?.content ?? "").matchAll(emojiPattern)) {
                const extension = match[1] ? "gif" : "webp";
                add(
                    `emoji:${match[3]}`,
                    "emojis",
                    match[3],
                    `${match[2]}.${extension}`,
                    [`https://cdn.discordapp.com/emojis/${match[3]}.${extension}?size=96&quality=lossless`],
                    "image"
                );
            }

            stickerItems(message).forEach((sticker, index) => {
                const id = String(sticker?.id ?? index);
                const format = Number(sticker?.format_type ?? sticker?.formatType ?? 1);
                if (format === 3 || !/^\d+$/.test(id)) return;
                const extension = format === 4 ? "gif" : "png";
                add(
                    `sticker:${id}`,
                    "stickers",
                    id,
                    `${sticker?.name ?? "sticker"}.${extension}`,
                    [`https://media.discordapp.net/stickers/${id}.${extension}?size=320&quality=lossless`],
                    "image"
                );
            });
        }

        if (options.embedMedia) {
            const attachmentUrls = new Set<string>();
            for (const attachment of Array.isArray(message?.attachments) ? message.attachments : []) {
                const url = safeExternalUrl(attachment?.url);
                const proxy = safeExternalUrl(attachment?.proxy_url);
                if (url) attachmentUrls.add(url);
                if (proxy) attachmentUrls.add(proxy);
            }
            const embeds = Array.isArray(message?.embeds) ? message.embeds : [];
            embeds.forEach((embed: any, index: number) => {
                const imageUrl = safeExternalUrl(embed?.image?.proxy_url ?? embed?.image?.url);
                const thumbnailUrl = safeExternalUrl(embed?.thumbnail?.proxy_url ?? embed?.thumbnail?.url);
                const proxyVideoUrl = safeExternalUrl(embed?.video?.proxy_url);
                const videoUrl = proxyVideoUrl || safeExternalUrl(embed?.video?.url);
                if (imageUrl && !attachmentUrls.has(imageUrl)) {
                    add(`embed:${message?.id}:${index}:image`, "embeds", `${messageId}-${index}-image`, "embed-image", [imageUrl, embed?.image?.url], "image");
                }
                if (thumbnailUrl && !attachmentUrls.has(thumbnailUrl)) {
                    add(`embed:${message?.id}:${index}:thumbnail`, "embeds", `${messageId}-${index}-thumbnail`, "embed-thumbnail", [thumbnailUrl, embed?.thumbnail?.url], "image");
                }
                if (videoUrl && !attachmentUrls.has(videoUrl) && (proxyVideoUrl || mediaKind({ url: videoUrl }) === "video")) {
                    add(`embed:${message?.id}:${index}:video`, "embeds", `${messageId}-${index}-video`, "embed-video", [videoUrl, embed?.video?.url], "video");
                }
            });
        }
    }

    return { aliases, requests };
}

function contentTypeMatches(kind: MediaKind, contentType: string, url: string): boolean {
    const type = contentType.toLowerCase().split(";", 1)[0].trim();
    if (type === "text/html" || type === "application/xhtml+xml") return false;
    if (!type || type === "application/octet-stream") return true;
    if (kind === "file") return true;
    if (kind === "image") return type.startsWith("image/");
    if (kind === "video") return type.startsWith("video/") || mediaKind({ url }) === "video";
    return type.startsWith("audio/") || mediaKind({ url }) === "audio";
}

async function fetchAsset(request: AssetRequest, signal: AbortSignal, fetcher: typeof fetch): Promise<AssetResult> {
    let finalError = "No usable URL was available.";
    for (const url of request.urls) {
        for (let attempt = 0; attempt < ASSET_RETRIES; attempt++) {
            throwIfAborted(signal);
            const timeoutController = new AbortController();
            const onAbort = () => timeoutController.abort();
            signal.addEventListener("abort", onAbort, { once: true });
            const timeout = window.setTimeout(() => timeoutController.abort(), ASSET_TIMEOUT_MS);
            try {
                const response = await fetcher(url, { credentials: "omit", signal: timeoutController.signal });
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                const contentType = response.headers.get("content-type") ?? "application/octet-stream";
                if (!contentTypeMatches(request.kind, contentType, url)) throw new Error(`unexpected content type ${contentType}`);
                const bytes = new Uint8Array(await response.arrayBuffer());
                if (!bytes.byteLength) throw new Error("empty response");
                return { bytes, contentType, kind: request.kind, originalUrl: request.originalUrl, path: request.path };
            } catch (error) {
                if (signal.aborted) throw abortError();
                finalError = error instanceof Error ? error.message : String(error);
                if (attempt < ASSET_RETRIES - 1) await delay(350 * 2 ** attempt, signal);
            } finally {
                window.clearTimeout(timeout);
                signal.removeEventListener("abort", onAbort);
            }
        }
    }
    return {
        contentType: "",
        error: finalError,
        kind: request.kind,
        originalUrl: request.originalUrl,
        path: request.path
    };
}

async function downloadAssetRequests(
    catalog: AssetCatalog,
    signal: AbortSignal,
    onProgress: (progress: ExportProgress) => void,
    fetcher: typeof fetch = fetch
): Promise<DownloadSummary> {
    const aliases = new Map<string, AssetResult>();
    const downloaded: AssetResult[] = [];
    const failures: AssetResult[] = [];
    let cursor = 0;
    let processed = 0;
    let downloadedBytes = 0;

    async function worker() {
        while (true) {
            throwIfAborted(signal);
            const index = cursor++;
            if (index >= catalog.requests.length) return;
            const request = catalog.requests[index];
            const result = await fetchAsset(request, signal, fetcher);
            for (const alias of request.aliases) aliases.set(alias, result);
            if (result.bytes) {
                downloaded.push(result);
                downloadedBytes += result.bytes.byteLength;
            } else {
                failures.push(result);
            }
            processed++;
            onProgress({ stage: "Downloading media", processed, total: catalog.requests.length, downloadedBytes, failures: failures.length });
        }
    }

    await Promise.all(Array.from({ length: Math.min(ASSET_CONCURRENCY, Math.max(1, catalog.requests.length)) }, worker));
    throwIfAborted(signal);
    return { aliases, downloaded, downloadedBytes, failures };
}

function renderMessageText(value: unknown, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const text = String(value ?? "");
    const tokenPattern = /<(a?):([A-Za-z0-9_]+):(\d+)>|https?:\/\/[^\s<>]+/g;
    let output = "";
    let offset = 0;
    for (const match of text.matchAll(tokenPattern)) {
        const index = match.index ?? 0;
        output += escapeHtml(text.slice(offset, index));
        if (match[3]) {
            const alias = `emoji:${match[3]}`;
            const result = resolve(alias);
            const alt = `:${match[2]}:`;
            output += renderImageAsset(alias, result, alt, mode, "emoji");
        } else {
            const url = safeExternalUrl(match[0]);
            output += url
                ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(match[0])}</a>`
                : escapeHtml(match[0]);
        }
        offset = index + match[0].length;
    }
    output += escapeHtml(text.slice(offset));
    return output.replace(/\r?\n/g, "<br>");
}

function assetSourceAttributes(alias: string, result: AssetResult | undefined, mode: HtmlMode): string {
    if (!result || result.error) return "";
    if (mode === "online") return `src="${escapeHtml(result.originalUrl)}"`;
    if (mode === "archive") return `src="${escapeHtml(result.path)}"`;
    return `data-asset-key="${escapeHtml(alias)}"`;
}

function localLinkAttributes(alias: string, result: AssetResult | undefined, mode: HtmlMode): string {
    if (!result || result.error) return "";
    if (mode === "online") return `href="${escapeHtml(result.originalUrl)}"`;
    if (mode === "archive") return `href="${escapeHtml(result.path)}"`;
    return `href="#" data-asset-key="${escapeHtml(alias)}"`;
}

function originalLink(result: AssetResult | undefined): string {
    const url = safeExternalUrl(result?.originalUrl);
    return url ? `<a class="original-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">Original online source</a>` : "";
}

function unavailableMedia(label: string, result: AssetResult | undefined): string {
    const reason = result?.error ? ` (${escapeHtml(result.error)})` : "";
    return `<span class="media-unavailable" role="note">${escapeHtml(label)} unavailable offline${reason}</span>${originalLink(result)}`;
}

function renderImageAsset(alias: string, result: AssetResult | undefined, alt: string, mode: HtmlMode, className = "media-image"): string {
    const source = assetSourceAttributes(alias, result, mode);
    if (!source) return unavailableMedia(alt, result);
    return `<img class="${className}" ${source} alt="${escapeHtml(alt)}" loading="lazy">`;
}

function renderAttachment(message: any, attachment: any, index: number, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const id = String(attachment?.id ?? index);
    const alias = `attachment:${message?.id}:${id}`;
    const result = resolve(alias);
    const name = String(attachment?.filename ?? "attachment");
    const description = String(attachment?.description ?? "");
    const details = [escapeHtml(name), attachment?.size ? formatBytes(attachment.size) : ""].filter(Boolean).join(" - ");
    const caption = `<figcaption>${details}${description ? `<span>${escapeHtml(description)}</span>` : ""}${originalLink(result)}</figcaption>`;
    const source = assetSourceAttributes(alias, result, mode);
    const link = localLinkAttributes(alias, result, mode);
    if (!source || !link) return `<div class="file-card">${unavailableMedia(name, result)}</div>`;

    const kind = mediaKind(attachment);
    if (kind === "image") return `<figure><a ${link} download>${renderImageAsset(alias, result, description || name, mode)}</a>${caption}</figure>`;
    if (kind === "video") return `<figure><video ${source} controls preload="metadata"></video>${caption}</figure>`;
    if (kind === "audio") return `<figure><audio ${source} controls preload="metadata"></audio>${caption}</figure>`;
    return `<div class="file-card"><a ${link} download>${escapeHtml(name)}</a><span>${details}</span>${originalLink(result)}</div>`;
}

function renderStickers(message: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const rendered = stickerItems(message).map(sticker => {
        const id = String(sticker?.id ?? "");
        const name = String(sticker?.name ?? "sticker");
        const format = Number(sticker?.format_type ?? sticker?.formatType ?? 1);
        if (format === 3) {
            const url = safeExternalUrl(`https://cdn.discordapp.com/stickers/${id}.json`);
            return `<span class="media-unavailable">${escapeHtml(name)} uses an unsupported Lottie format</span><a class="original-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">Original Lottie data</a>`;
        }
        if (!/^\d+$/.test(id)) return "";
        return renderImageAsset(`sticker:${id}`, resolve(`sticker:${id}`), name, mode, "sticker");
    }).filter(Boolean).join("");
    return rendered ? `<div class="sticker-row">${rendered}</div>` : "";
}

function renderEmbed(message: any, embed: any, index: number, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const title = String(embed?.title ?? "");
    const description = renderMessageText(embed?.description ?? "", resolve, mode);
    const url = safeExternalUrl(embed?.url);
    const author = escapeHtml(embed?.author?.name ?? "");
    const provider = escapeHtml(embed?.provider?.name ?? "");
    const fields = Array.isArray(embed?.fields) ? embed.fields.map((field: any) =>
        `<div class="embed-field"><strong>${escapeHtml(field?.name ?? "")}</strong><div>${renderMessageText(field?.value ?? "", resolve, mode)}</div></div>`
    ).join("") : "";
    const imageAlias = `embed:${message?.id}:${index}:image`;
    const thumbnailAlias = `embed:${message?.id}:${index}:thumbnail`;
    const videoAlias = `embed:${message?.id}:${index}:video`;
    const imageResult = resolve(imageAlias);
    const thumbnailResult = resolve(thumbnailAlias);
    const videoResult = resolve(videoAlias);
    const image = imageResult ? renderImageAsset(imageAlias, imageResult, "Embedded image", mode, "embed-image") : "";
    const thumbnail = thumbnailResult ? renderImageAsset(thumbnailAlias, thumbnailResult, "Embedded thumbnail", mode, "embed-thumbnail") : "";
    const videoSource = assetSourceAttributes(videoAlias, videoResult, mode);
    const video = videoResult
        ? videoSource ? `<video class="embed-video" ${videoSource} controls preload="metadata"></video>` : unavailableMedia("Embedded video", videoResult)
        : "";
    const linkedTitle = title
        ? url ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(title)}</a>` : escapeHtml(title)
        : "";
    if (!linkedTitle && !description && !fields && !image && !thumbnail && !video) return "";
    return `<aside class="embed">${thumbnail}<div class="embed-body">${author || provider ? `<div class="embed-meta">${[author, provider].filter(Boolean).join(" - ")}</div>` : ""}${linkedTitle ? `<div class="embed-title">${linkedTitle}</div>` : ""}${description ? `<div>${description}</div>` : ""}${fields ? `<div class="embed-fields">${fields}</div>` : ""}${video}${image}</div></aside>`;
}

function renderMessageMedia(message: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const attachments = (Array.isArray(message?.attachments) ? message.attachments : [])
        .map((attachment: any, index: number) => renderAttachment(message, attachment, index, resolve, mode))
        .join("");
    const embeds = (Array.isArray(message?.embeds) ? message.embeds : [])
        .map((embed: any, index: number) => renderEmbed(message, embed, index, resolve, mode))
        .join("");
    const stickers = renderStickers(message, resolve, mode);
    return attachments || embeds || stickers ? `<div class="media-stack">${attachments}${embeds}${stickers}</div>` : "";
}

function renderAvatar(author: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const alias = `avatar:${author?.id}:${author?.avatar}`;
    const result = resolve(alias);
    if (result) return renderImageAsset(alias, result, "", mode, "avatar");
    const name = String(author?.global_name ?? author?.username ?? "?").trim();
    return `<span class="avatar avatar-fallback" aria-hidden="true">${escapeHtml(name.slice(0, 1).toUpperCase() || "?")}</span>`;
}

function conversationStyles(): string {
    return String.raw`:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#313338;color:#dbdee1;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:15px;line-height:1.46;padding:28px 18px}main{max-width:960px;margin:0 auto}h1{margin:0;color:#f2f3f5;font-size:24px;overflow-wrap:anywhere}.subtitle{margin:4px 0 24px;color:#949ba4;font-size:13px}.message{display:grid;grid-template-columns:46px minmax(0,1fr);column-gap:12px;padding:11px 10px 3px;border-radius:6px}.message.continuation{padding-top:3px}.message:hover{background:#2e3035}.avatar-slot{grid-column:1;grid-row:1/span 2}.avatar{display:grid;width:40px;height:40px;border-radius:50%;object-fit:cover;place-items:center;background:#5865f2;color:#fff;font-weight:700}.message-body{grid-column:2;min-width:0}.message-header{display:flex;align-items:baseline;gap:7px;min-width:0}.author{color:#f2f3f5;font-weight:700;overflow-wrap:anywhere}.username,.timestamp{color:#949ba4;font-size:12px}.continuation-time{grid-column:1;color:#949ba4;font-size:10px;text-align:right;padding-top:4px}.content{white-space:normal;overflow-wrap:anywhere;word-break:break-word}.content pre,.content code{white-space:pre-wrap;overflow-wrap:anywhere}.content a,.embed a,.file-card a,.original-link{color:#00a8fc;text-decoration:none;overflow-wrap:anywhere}.content a:hover,.embed a:hover,.file-card a:hover,.original-link:hover{text-decoration:underline}.emoji{display:inline-block;width:auto;height:1.4em;vertical-align:-.32em;object-fit:contain}.media-stack{display:flex;flex-direction:column;align-items:flex-start;gap:10px;margin-top:7px}.media-stack figure{max-width:min(100%,720px);margin:0}.media-stack img:not(.emoji):not(.avatar){display:block;max-width:100%;max-height:520px;border-radius:6px;object-fit:contain;background:#1e1f22}.media-stack video{display:block;max-width:100%;max-height:520px;border-radius:6px;background:#1e1f22}.media-stack audio{display:block;width:min(100%,440px)}figcaption{display:flex;flex-wrap:wrap;gap:4px 10px;margin-top:4px;color:#b5bac1;font-size:12px}figcaption span{flex-basis:100%}.original-link{font-size:11px}.file-card{display:flex;flex-wrap:wrap;align-items:center;gap:5px 10px;max-width:100%;padding:9px 11px;border:1px solid #4e5058;border-radius:6px;background:#2b2d31;overflow-wrap:anywhere}.file-card span{color:#949ba4;font-size:12px}.media-unavailable{display:inline-block;padding:8px 10px;border:1px dashed #5d6068;border-radius:5px;color:#b5bac1;background:#2b2d31;font-size:12px}.sticker-row{display:flex;flex-wrap:wrap;gap:8px}.sticker{width:160px;height:auto}.embed{display:flex;gap:12px;max-width:min(100%,720px);padding:10px 12px;border-left:4px solid #4f5660;border-radius:4px;background:#2b2d31;overflow-wrap:anywhere}.embed-body{min-width:0;flex:1}.embed-meta{margin-bottom:3px;color:#b5bac1;font-size:12px}.embed-title{margin-bottom:4px;color:#f2f3f5;font-weight:700}.embed-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-top:8px}.embed-field{min-width:0;font-size:13px}.embed-field strong{display:block;color:#f2f3f5}.embed-thumbnail{order:2;width:80px;height:80px;object-fit:cover}.embed-image,.embed-video{max-width:100%;max-height:420px;margin-top:9px}.archive-footer{margin-top:26px;padding-top:12px;border-top:1px solid #3f4147;color:#949ba4;font-size:11px}@media(max-width:580px){body{padding:17px 7px}.message{grid-template-columns:38px minmax(0,1fr);column-gap:8px;padding-inline:4px}.avatar{width:34px;height:34px}.embed{gap:8px}.embed-thumbnail{width:60px;height:60px}.embed-fields{grid-template-columns:1fr}}`;
}

function renderConversationHtml(
    messages: any[],
    channelName: string,
    mode: HtmlMode,
    aliases: Map<string, AssetResult>,
    embeddedAssets?: EmbeddedAssetPayload
): string {
    const resolve = (alias: string) => aliases.get(alias);
    const rows: string[] = [];
    let previousAuthor = "";
    let previousTimestamp = 0;
    for (const message of messages) {
        const authorId = String(message?.author?.id ?? "");
        const timestamp = new Date(message?.timestamp ?? 0);
        const timestampMs = timestamp.getTime();
        const grouped = Boolean(authorId && authorId === previousAuthor && Number.isFinite(timestampMs) && timestampMs - previousTimestamp <= GROUP_WINDOW_MS);
        const author = escapeHtml(message?.author?.global_name ?? message?.author?.username ?? "Unknown user");
        const username = escapeHtml(message?.author?.username ?? "unknown");
        const iso = Number.isFinite(timestampMs) ? timestamp.toISOString() : "";
        const displayTime = Number.isFinite(timestampMs) ? timestamp.toLocaleString() : "Unknown time";
        const content = renderMessageText(message?.content ?? "", resolve, mode);
        const media = renderMessageMedia(message, resolve, mode);
        const header = grouped
            ? `<time class="continuation-time" datetime="${escapeHtml(iso)}" title="${escapeHtml(displayTime)}">${escapeHtml(timestamp.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}</time>`
            : `<div class="avatar-slot">${renderAvatar(message?.author, resolve, mode)}</div><header class="message-header"><span class="author">${author}</span><span class="username">@${username}</span><time class="timestamp" datetime="${escapeHtml(iso)}">${escapeHtml(displayTime)}</time></header>`;
        rows.push(`<article class="message${grouped ? " continuation" : ""}" data-message-id="${escapeHtml(message?.id ?? "")}">${header}<div class="message-body"><div class="content">${content || (media ? "" : "<em>[no text or media]</em>")}</div>${media}</div></article>`);
        previousAuthor = authorId;
        previousTimestamp = Number.isFinite(timestampMs) ? timestampMs : 0;
    }

    const title = escapeHtml(channelName);
    const modeNote = mode === "online"
        ? "Online HTML export. Internet access is required to load media from its original source."
        : mode === "archive" ? "Offline archive. Media is loaded from the included assets folders." : "Self-contained offline HTML export.";
    const assetPayload = mode === "single"
        ? `<script type="application/json" id="asset-data">${JSON.stringify(embeddedAssets ?? { aliases: {}, data: {} }).replace(/</g, "\\u003c")}</script><script>(()=>{const n=document.getElementById("asset-data");if(!n)return;const a=JSON.parse(n.textContent||"{}");document.querySelectorAll("[data-asset-key]").forEach(e=>{const k=e.getAttribute("data-asset-key")||"";const u=a.data?.[a.aliases?.[k]];if(!u)return;if(e.tagName==="A")e.setAttribute("href",u);else e.setAttribute("src",u)})})()</script>`
        : "";
    const scriptPolicy = mode === "single" ? "'unsafe-inline'" : "'none'";
    const mediaPolicy = mode === "online" ? "https: http: data:" : mode === "single" ? "data:" : "'self' data:";
    return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${mediaPolicy}; media-src ${mediaPolicy}; style-src 'unsafe-inline'; script-src ${scriptPolicy}"><title>${title}</title><style>${conversationStyles()}</style></head><body><main><h1>${title}</h1><p class="subtitle">${escapeHtml(modeNote)} ${messages.length} message${messages.length === 1 ? "" : "s"}.</p>${rows.join("\n")}<footer class="archive-footer">Generated locally by Equicord ExportDM. No analytics or remote scripts are included.</footer></main>${assetPayload}</body></html>`;
}

function rawJson(messages: any[], channelName: string, exportedAt = new Date().toISOString()): string {
    return JSON.stringify({ channel: channelName, exportedAt, messages }, null, 2);
}

function bytesToBase64(bytes: Uint8Array): string {
    let binary = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return btoa(binary);
}

function buildDownloadReport(summary: DownloadSummary): string {
    const lines = [
        "Equicord ExportDM download report",
        "",
        `Downloaded assets: ${summary.downloaded.length}`,
        `Downloaded bytes: ${summary.downloadedBytes}`,
        `Failed assets: ${summary.failures.length}`,
        ""
    ];
    if (summary.failures.length) {
        lines.push("Failures:");
        summary.failures.forEach(failure => lines.push(`- ${failure.path} | ${failure.originalUrl} | ${failure.error ?? "Unknown error"}`));
    } else {
        lines.push("All requested assets were downloaded successfully.");
    }
    return lines.join("\r\n");
}

function createOfflineArchive(
    messages: any[],
    channelName: string,
    options: ExportOptions,
    summary: DownloadSummary,
    exportedAt = new Date().toISOString()
): ArchiveBuildResult {
    const html = renderConversationHtml(messages, channelName, "archive", summary.aliases);
    const report = buildDownloadReport(summary);
    const manifest = {
        format: "Equicord ExportDM Offline Archive",
        version: 1,
        channel: channelName,
        exportedAt,
        messageCount: messages.length,
        options,
        downloadedBytes: summary.downloadedBytes,
        downloadedAssets: summary.downloaded.map(asset => ({ path: asset.path, contentType: asset.contentType, size: asset.bytes?.byteLength ?? 0, originalUrl: asset.originalUrl })),
        failedAssets: summary.failures.map(asset => ({ path: asset.path, originalUrl: asset.originalUrl, error: asset.error }))
    };
    const files: Zippable = {
        "index.html": [strToU8(html), { level: 6 }],
        "messages.json": [strToU8(rawJson(messages, channelName, exportedAt)), { level: 6 }],
        "manifest.json": [strToU8(JSON.stringify(manifest, null, 2)), { level: 6 }],
        "download-report.txt": [strToU8(report), { level: 6 }],
        "assets/attachments/": new Uint8Array(),
        "assets/avatars/": new Uint8Array(),
        "assets/emojis/": new Uint8Array(),
        "assets/stickers/": new Uint8Array(),
        "assets/embeds/": new Uint8Array()
    };
    for (const asset of summary.downloaded) {
        if (asset.bytes) files[asset.path] = [asset.bytes, { level: 0 }];
    }
    return { bytes: zipSync(files, { level: 6 }), html, manifest, report };
}

function createSingleHtml(messages: any[], channelName: string, summary: DownloadSummary): string {
    const embeddedAssets: EmbeddedAssetPayload = { aliases: {}, data: {} };
    for (const [alias, result] of summary.aliases) {
        if (!result.bytes || result.error) continue;
        if (!embeddedAssets.data[result.path]) {
            embeddedAssets.data[result.path] = `data:${result.contentType || "application/octet-stream"};base64,${bytesToBase64(result.bytes)}`;
        }
        embeddedAssets.aliases[alias] = result.path;
    }
    return renderConversationHtml(messages, channelName, "single", summary.aliases, embeddedAssets);
}

function retainSkippedAssetLinks(allAssets: AssetCatalog, summary: DownloadSummary) {
    for (const [alias, request] of allAssets.aliases) {
        if (summary.aliases.has(alias)) continue;
        summary.aliases.set(alias, {
            contentType: "",
            error: "Not included by the selected media options.",
            kind: request.kind,
            originalUrl: request.originalUrl,
            path: request.path
        });
    }
}

function createOnlineAliases(catalog: AssetCatalog): Map<string, AssetResult> {
    const aliases = new Map<string, AssetResult>();
    for (const [alias, request] of catalog.aliases) {
        aliases.set(alias, { contentType: "", kind: request.kind, originalUrl: request.originalUrl, path: request.path });
    }
    return aliases;
}

function downloadBlob(content: BlobPart, filename: string, mime: string) {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function conversationSummary(messages: any[]) {
    let attachmentCount = 0;
    let knownBytes = 0;
    for (const message of messages) {
        for (const attachment of Array.isArray(message?.attachments) ? message.attachments : []) {
            attachmentCount++;
            const size = Number(attachment?.size ?? 0);
            if (Number.isFinite(size) && size > 0) knownBytes += size;
        }
    }
    const messageBytes = new TextEncoder().encode(JSON.stringify(messages)).byteLength;
    const estimatedSingleHtmlBytes = messageBytes + Math.ceil(knownBytes / 3) * 4;
    return { attachmentCount, estimatedSingleHtmlBytes, knownBytes, messageCount: messages.length };
}

function ExportModal({ rootProps, channelId }: { rootProps: RenderModalProps; channelId: string; }) {
    const [format, setFormat] = useState<ExportFormat>("offlineArchive");
    const [options, setOptions] = useState<ExportOptions>(DEFAULT_OPTIONS);
    const [messages, setMessages] = useState<any[] | null>(null);
    const [status, setStatus] = useState("");
    const [busy, setBusy] = useState(false);
    const [progress, setProgress] = useState<ExportProgress>({ stage: "", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
    const controllerRef = React.useRef<AbortController | null>(null);
    const channel = ChannelStore.getChannel(channelId);
    const channelName = channel?.name ?? channelId;
    const offline = format === "offlineArchive" || format === "singleHtml";
    const summary = messages ? conversationSummary(messages) : null;

    React.useEffect(() => () => controllerRef.current?.abort(), []);

    function beginOperation(stage: string) {
        controllerRef.current?.abort();
        const controller = new AbortController();
        controllerRef.current = controller;
        setBusy(true);
        setStatus("");
        setProgress({ stage, processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
        return controller;
    }

    function finishOperation(controller: AbortController) {
        if (controllerRef.current === controller) controllerRef.current = null;
        setBusy(false);
    }

    async function prepareMessages() {
        if (busy) return;
        const controller = beginOperation("Fetching messages");
        try {
            const collected = await fetchAllMessages(channelId, controller.signal, count => {
                setProgress({ stage: "Fetching messages", processed: count, total: 0, downloadedBytes: 0, failures: 0 });
            });
            throwIfAborted(controller.signal);
            setMessages(collected);
            setProgress({ stage: "Ready", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
            setStatus(`Ready to export ${collected.length} message${collected.length === 1 ? "" : "s"}.`);
        } catch (error) {
            if (isAbortError(error)) {
                setProgress({ stage: "Cancelled", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
                setStatus("Preparation cancelled.");
            } else {
                setProgress({ stage: "Failed", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
                setStatus(`Could not fetch messages: ${error instanceof Error ? error.message : String(error)}`);
            }
        } finally {
            finishOperation(controller);
        }
    }

    async function createExport() {
        if (busy || !messages) return;
        if (format === "singleHtml" && (summary?.estimatedSingleHtmlBytes ?? 0) >= SINGLE_HTML_WARNING_BYTES) {
            const proceed = window.confirm(`Single HTML is estimated at least ${formatBytes(summary?.estimatedSingleHtmlBytes)} from known messages and attachments. It may be very large or slow. Offline Archive is recommended. Continue anyway?`);
            if (!proceed) {
                setStatus("Single HTML export cancelled before downloading media.");
                return;
            }
        }

        const controller = beginOperation(format === "json" || format === "onlineHtml" ? "Building document" : "Preparing media list");
        try {
            const baseName = `${safeFilename(channelName)}-export`;
            if (format === "json") {
                downloadBlob(rawJson(messages, channelName), `${baseName}.json`, "application/json;charset=utf-8");
            } else {
                const catalog = collectAssetRequests(messages, offline ? options : DEFAULT_OPTIONS);
                if (format === "onlineHtml") {
                    const html = renderConversationHtml(messages, channelName, "online", createOnlineAliases(catalog));
                    throwIfAborted(controller.signal);
                    downloadBlob(html, `${baseName}-online.html`, "text/html;charset=utf-8");
                } else {
                    setProgress({ stage: "Downloading media", processed: 0, total: catalog.requests.length, downloadedBytes: 0, failures: 0 });
                    const assets = await downloadAssetRequests(catalog, controller.signal, setProgress);
                    retainSkippedAssetLinks(collectAssetRequests(messages, DEFAULT_OPTIONS), assets);
                    throwIfAborted(controller.signal);
                    setProgress(current => ({ ...current, stage: format === "offlineArchive" ? "Building ZIP archive" : "Building self-contained HTML" }));
                    await delay(0, controller.signal);
                    if (format === "offlineArchive") {
                        const archive = createOfflineArchive(messages, channelName, options, assets);
                        throwIfAborted(controller.signal);
                        downloadBlob(archive.bytes as BlobPart, `${baseName}-offline.zip`, "application/zip");
                    } else {
                        const html = createSingleHtml(messages, channelName, assets);
                        throwIfAborted(controller.signal);
                        downloadBlob(html, `${baseName}-single.html`, "text/html;charset=utf-8");
                    }
                    const completion = assets.failures.length ? "Partial completion" : "Complete";
                    setProgress(current => ({ ...current, stage: completion }));
                    setStatus(`${completion}: ${messages.length} messages, ${assets.downloaded.length} assets downloaded, ${assets.failures.length} failed. Offline failures are shown in the transcript${format === "offlineArchive" ? " and download-report.txt" : ""}.`);
                    return;
                }
            }
            setProgress(current => ({ ...current, stage: "Complete" }));
            setStatus(`Complete: ${messages.length} message${messages.length === 1 ? "" : "s"} exported.`);
        } catch (error) {
            if (isAbortError(error)) {
                setProgress(current => ({ ...current, stage: "Cancelled" }));
                setStatus("Export cancelled. No completed download was created.");
            } else {
                setProgress(current => ({ ...current, stage: "Failed" }));
                setStatus(`Export failed: ${error instanceof Error ? error.message : String(error)}`);
            }
        } finally {
            finishOperation(controller);
        }
    }

    function updateOption(key: keyof ExportOptions, checked: boolean) {
        setOptions(current => ({ ...current, [key]: checked }));
    }

    const progressPercent = progress.total > 0 ? Math.min(100, progress.processed / progress.total * 100) : 0;
    return (
        <Modal {...rootProps} size="medium" title={`Export - ${channelName}`}>
            <style>{EXPORT_MODAL_CSS}</style>
            <div className="eq-export-modal">
                <div className="eq-export-format-grid" role="radiogroup" aria-label="Export format">
                    {FORMAT_CHOICES.map(choice => (
                        <button
                            key={choice.id}
                            type="button"
                            role="radio"
                            aria-checked={format === choice.id}
                            className={`eq-export-format${format === choice.id ? " eq-export-format--selected" : ""}`}
                            disabled={busy}
                            onClick={() => setFormat(choice.id)}
                        >
                            <span className="eq-export-format-head">{choice.title}{choice.badge && <span className="eq-export-badge">{choice.badge}</span>}</span>
                            <span className="eq-export-format-desc">{choice.description}</span>
                        </button>
                    ))}
                </div>

                {offline && (
                    <div className="eq-export-options" aria-label="Offline media options">
                        <label className="eq-export-option"><input type="checkbox" checked={options.attachments} disabled={busy} onChange={event => updateOption("attachments", event.currentTarget.checked)} />Attachments</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.avatars} disabled={busy} onChange={event => updateOption("avatars", event.currentTarget.checked)} />Author avatars</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.emojisStickers} disabled={busy} onChange={event => updateOption("emojisStickers", event.currentTarget.checked)} />Emojis and stickers</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.embedMedia} disabled={busy} onChange={event => updateOption("embedMedia", event.currentTarget.checked)} />Embed previews</label>
                    </div>
                )}

                {format === "onlineHtml" && <div className="eq-export-note">Internet access is required whenever this HTML file displays online media.</div>}
                {format === "singleHtml" && <div className="eq-export-note eq-export-warning">Downloaded media is base64-embedded once per asset. The resulting file can be much larger and slower than Offline Archive.</div>}

                {summary && (
                    <div className="eq-export-summary">
                        <strong>Export summary</strong>
                        <div className="eq-export-summary-grid">
                            <span className="eq-export-metric">Messages<strong>{summary.messageCount}</strong></span>
                            <span className="eq-export-metric">Attachments<strong>{summary.attachmentCount}</strong></span>
                            <span className="eq-export-metric">{format === "singleHtml" ? "Estimated output" : "Known media size"}<strong>{formatBytes(format === "singleHtml" ? summary.estimatedSingleHtmlBytes : summary.knownBytes)}</strong></span>
                        </div>
                    </div>
                )}

                {(busy || progress.stage) && (
                    <div className="eq-export-progress" aria-live="polite">
                        <div className="eq-export-progress-line"><strong>{progress.stage}</strong><span>{progress.total ? `${progress.processed}/${progress.total} assets` : `${progress.processed} messages`}</span></div>
                        <div className="eq-export-progress-line"><span>{formatBytes(progress.downloadedBytes)} downloaded</span><span>{progress.failures} failures</span></div>
                        {progress.total > 0 && <div className="eq-export-bar" aria-hidden="true"><span style={{ width: `${progressPercent}%` }} /></div>}
                    </div>
                )}

                {status && <div className="eq-export-status" role="status">{status}</div>}
                <Divider style={{ margin: "16px 0 0" }} />
                <div className="eq-export-actions">
                    <button type="button" className="eq-export-button eq-export-button--primary" disabled={busy} onClick={messages ? createExport : prepareMessages}>
                        {busy ? "Working..." : messages ? "Create export" : "Prepare export"}
                    </button>
                    {busy && <button type="button" className="eq-export-button eq-export-button--cancel" onClick={() => controllerRef.current?.abort()}>Cancel</button>}
                </div>
            </div>
        </Modal>
    );
}

const patchDMContext: NavContextMenuPatchCallback = (children, { channel }) => {
    if (!channel) return;
    children.push(
        <Menu.MenuItem
            id="export-dm"
            key="export-dm"
            label="Export DM"
            action={() => openModal(props => <ExportModal rootProps={props} channelId={channel.id} />)}
        />
    );
};

const patchChannelContext: NavContextMenuPatchCallback = (children, { channel }) => {
    if (!channel) return;
    children.push(
        <Menu.MenuItem
            id="export-dm"
            key="export-dm"
            label="Export Messages"
            action={() => openModal(props => <ExportModal rootProps={props} channelId={channel.id} />)}
        />
    );
};

export const ExportDmTestApi = {
    collectAssetRequests,
    createOfflineArchive,
    createOnlineAliases,
    createSingleHtml,
    downloadAssetRequests,
    renderConversationHtml,
    safeFilename,
    sanitizeFilenamePart
};

export default definePlugin({
    name: "ExportDM",
    description: "Export messages as raw JSON, online HTML, a complete offline ZIP archive, or one self-contained HTML file.",
    authors: [{ name: "sqlu", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ContextMenuAPI"],
    start() {
        addContextMenuPatch("gdm-context", patchDMContext);
        addContextMenuPatch("user-context", patchDMContext);
        addContextMenuPatch("channel-context", patchChannelContext);
    },
    stop() {
        removeContextMenuPatch("gdm-context", patchDMContext);
        removeContextMenuPatch("user-context", patchDMContext);
        removeContextMenuPatch("channel-context", patchChannelContext);
    }
});
