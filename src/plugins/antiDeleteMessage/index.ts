/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { Constants, RestAPI, UserStore } from "@webpack/common";
const logger = new Logger("AntiDeleteMessage");
const settings = definePluginSettings({
    enabled: { type: OptionType.BOOLEAN, description: "Enable automatic message restoration", default: true },
    dmProtection: { type: OptionType.BOOLEAN, description: "Also protect DMs", default: false },
    maxCacheSize: { type: OptionType.NUMBER, description: "Max messages cached", default: 500 },
    serverBlacklist: { type: OptionType.STRING, description: "Server IDs to ignore (comma-separated)", default: "" }
});
const DB_KEY = "AntiDeleteMessage_cache";
interface CachedMessage { content: string; channelId: string; nonce: string; guildId?: string; messageReference?: any; savedAt: number; }
let memCache: Record<string, CachedMessage> = {}; let dbLoaded = false;
async function loadCache() { try { const stored = await DataStore.get<Record<string, CachedMessage>>(DB_KEY); if (stored && typeof stored === "object") memCache = stored; } catch (error) { logger.error("Failed to load the message cache", error); } finally { dbLoaded = true; } }
let saveTimer: ReturnType<typeof setTimeout> | null = null;
const resendTimers = new Set<ReturnType<typeof setTimeout>>();
function scheduleSave() { if (saveTimer) clearTimeout(saveTimer); saveTimer = setTimeout(async () => { saveTimer = null; try { await DataStore.set(DB_KEY, memCache); } catch (error) { logger.error("Failed to save the message cache", error); } }, 1000); }
function getBlacklist() { return new Set((settings.store.serverBlacklist ?? "").split(",").map((s: string) => s.trim()).filter(Boolean)); }
function addToCache(id: string, data: CachedMessage) { const max = Math.max(10, Math.min(5000, Number(settings.store.maxCacheSize) || 500)); const ids = Object.keys(memCache); if (ids.length >= max) ids.sort((a, b) => (memCache[a].savedAt ?? 0) - (memCache[b].savedAt ?? 0)).slice(0, Math.max(1, Math.floor(max * 0.1))).forEach(k => delete memCache[k]); memCache[id] = data; scheduleSave(); }
async function resendMessage(c: CachedMessage) { try { const body: any = { content: c.content, flags: 0, mobile_network_type: "unknown", nonce: c.nonce, tts: false }; if (c.messageReference) body.message_reference = c.messageReference; const response = await RestAPI.post({ url: Constants.Endpoints.MESSAGES(c.channelId), body }); const status = Number(response?.status ?? 200); if (response?.ok === false || status >= 400) throw new Error(`Discord returned ${status}`); } catch (error) { logger.error("Failed to restore a deleted message", error); } }
export default definePlugin({
    name: "AntiDeleteMessage", description: "Automatically resends your messages if someone deletes them.", authors: [{ name: "Nightcord", id: 0n }], enabledByDefault: false, settings,
    flux: {
        MESSAGE_CREATE({ message, guildId }: { message: { id: string; author: { id: string; }; content: string; channel_id: string; nonce?: string; message_reference?: any; }; guildId?: string; }) {
            if (!settings.store.enabled || !dbLoaded) return;
            const me = UserStore.getCurrentUser(); if (!me || message.author.id !== me.id || !message.content?.trim()) return;
            if (!guildId && !settings.store.dmProtection) return;
            if (guildId && getBlacklist().has(guildId)) return;
            addToCache(message.id, { content: message.content, channelId: message.channel_id, nonce: message.id, guildId, messageReference: message.message_reference, savedAt: Date.now() });
        },
        MESSAGE_DELETE({ id, channelId }: { id: string; channelId: string; }) {
            if (!settings.store.enabled) return; const c = memCache[id]; if (!c) return;
            if (c.guildId && getBlacklist().has(c.guildId)) { delete memCache[id]; scheduleSave(); return; }
            delete memCache[id]; scheduleSave(); const timer = setTimeout(() => { resendTimers.delete(timer); resendMessage(c); }, 400); resendTimers.add(timer);
        },
    },
    async start() { await loadCache(); },
    stop() { if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; DataStore.set(DB_KEY, memCache).catch(error => logger.error("Failed to flush the message cache", error)); } resendTimers.forEach(timer => clearTimeout(timer)); resendTimers.clear(); memCache = {}; dbLoaded = false; }
});
