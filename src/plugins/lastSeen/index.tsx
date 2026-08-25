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
import ErrorBoundary from "@components/ErrorBoundary";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findComponentByCodeLazy } from "@webpack";
import { React, useStateFromStores } from "@webpack/common";

const Section = findComponentByCodeLazy("headingVariant:", '"section"', "headingIcon:");
const PresenceStore = findByPropsLazy("getStatus", "getActivities");
const logger = new Logger("LastSeen");

const settings = definePluginSettings({
    language: {
        type: OptionType.SELECT,
        description: "Language",
        options: [
            { label: "English", value: "en", default: true },
            { label: "Francais", value: "fr" }
        ]
    }
});

const STORAGE_KEY = "LastSeen_entries_v2";
const LEGACY_PREFIX = "lastseen_";
const MAX_ENTRIES = 2000;
const SAVE_DELAY_MS = 1000;

let entries: Record<string, number> = {};
let cacheLoaded = false;
let loadPromise: Promise<void> | null = null;
let saveTimer: ReturnType<typeof setTimeout> | null = null;
const listeners = new Set<() => void>();

function notifyListeners() {
    listeners.forEach(listener => listener());
}

function trimEntries() {
    const ids = Object.keys(entries);
    if (ids.length <= MAX_ENTRIES) return;
    ids.sort((a, b) => entries[b] - entries[a]);
    entries = Object.fromEntries(ids.slice(0, MAX_ENTRIES).map(id => [id, entries[id]]));
}

async function ensureCacheLoaded() {
    if (cacheLoaded) return;
    if (loadPromise) return loadPromise;

    loadPromise = (async () => {
        try {
            const stored = await DataStore.get<Record<string, number>>(STORAGE_KEY);
            const valid: Record<string, number> = {};
            if (stored && typeof stored === "object") {
                for (const [id, timestamp] of Object.entries(stored)) {
                    const value = Number(timestamp);
                    if (/^\d+$/.test(id) && Number.isFinite(value) && value > 0) valid[id] = value;
                }
            }
            entries = { ...valid, ...entries };
            trimEntries();
        } catch (error) {
            logger.error("Failed to load stored activity timestamps", error);
        } finally {
            cacheLoaded = true;
            loadPromise = null;
            notifyListeners();
        }
    })();

    return loadPromise;
}

function scheduleSave() {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(async () => {
        saveTimer = null;
        await ensureCacheLoaded();
        try {
            await DataStore.set(STORAGE_KEY, entries);
        } catch (error) {
            logger.error("Failed to save activity timestamps", error);
        }
    }, SAVE_DELAY_MS);
}

function recordSeen(userId: string | undefined, timestamp = Date.now()) {
    if (!userId || !/^\d+$/.test(userId)) return;
    void ensureCacheLoaded();
    entries[userId] = timestamp;
    trimEntries();
    scheduleSave();
    notifyListeners();
}

async function migrateLegacyEntry(userId: string) {
    await ensureCacheLoaded();
    if (entries[userId]) return;
    const legacyKey = LEGACY_PREFIX + userId;
    try {
        const value = Number(await DataStore.get(legacyKey));
        if (Number.isFinite(value) && value > 0) {
            recordSeen(userId, value);
            await DataStore.del(legacyKey);
        }
    } catch (error) {
        logger.warn("Could not migrate a legacy activity timestamp", error);
    }
}

function formatTimestamp(timestamp: number): string {
    const now = new Date();
    const date = new Date(timestamp);
    const language = settings.store.language ?? "en";
    const locale = language === "fr" ? "fr-FR" : "en-US";
    const time = date.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit", second: "2-digit" });

    if (date.toDateString() === now.toDateString()) return language === "fr" ? `Aujourd'hui a ${time}` : `Today at ${time}`;
    const yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    if (date.toDateString() === yesterday.toDateString()) return language === "fr" ? `Hier a ${time}` : `Yesterday at ${time}`;
    const day = date.toLocaleDateString(locale, { day: "numeric", month: "short" });
    return language === "fr" ? `Le ${day} a ${time}` : `${day} at ${time}`;
}

function LastSeenText({ userId }: { userId: string; }) {
    const status = useStateFromStores([PresenceStore], () => PresenceStore.getStatus(userId));
    const [, forceUpdate] = React.useState(0);

    React.useEffect(() => {
        let active = true;
        const listener = () => { if (active) forceUpdate(value => value + 1); };
        listeners.add(listener);
        void migrateLegacyEntry(userId);
        return () => { active = false; listeners.delete(listener); };
    }, [userId]);

    if (!cacheLoaded) return null;
    const language = settings.store.language ?? "en";
    const isOnline = status && status !== "offline" && status !== "invisible";
    let content: string;
    let color = "#dcddde";

    if (isOnline) {
        if (status === "idle") { content = language === "fr" ? "Inactif" : "Idle"; color = "#faa81a"; }
        else if (status === "dnd") { content = language === "fr" ? "Ne pas deranger" : "Do Not Disturb"; color = "#ed4245"; }
        else if (status === "streaming") { content = language === "fr" ? "En direct" : "Streaming"; color = "#593695"; }
        else { content = language === "fr" ? "En ligne" : "Online"; color = "#3ba55d"; }
    } else if (entries[userId]) {
        content = formatTimestamp(entries[userId]);
        color = "#b5bac1";
    } else {
        content = language === "fr" ? "Pas encore trace" : "Not tracked yet";
        color = "#80848e";
    }

    return <div style={{ fontSize: "14px", lineHeight: "18px", color, WebkitTextFillColor: color, fontWeight: 400, userSelect: "text" } as React.CSSProperties}>{content}</div>;
}

const LastSeenSection = ErrorBoundary.wrap(({ userId, isSideBar }: { userId: string; isSideBar: boolean; }) => (
    <Section heading="Last Seen" headingVariant={isSideBar ? "text-xs/semibold" : "text-xs/medium"} headingColor={isSideBar ? "text-strong" : "text-default"}>
        <LastSeenText userId={userId} />
    </Section>
), { noop: true });

export default definePlugin({
    name: "LastSeen",
    description: "Shows when a user was last seen. Text always visible.",
    authors: [{ name: "nightcord", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ProfileSectionsAPI"],
    settings,
    renderProfileSection: {
        render: LastSeenSection,
        priority: 0
    },
    flux: {
        PRESENCE_UPDATE(event: any) {
            if (Array.isArray(event?.updates)) event.updates.forEach((update: any) => recordSeen(update?.user?.id ?? update?.userId ?? update?.user_id));
            else recordSeen(event?.user?.id ?? event?.userId ?? event?.user_id);
        },
        PRESENCE_UPDATES(event: any) {
            const updates = Array.isArray(event?.updates) ? event.updates : Array.isArray(event) ? event : [event];
            updates.forEach((update: any) => recordSeen(update?.user?.id ?? update?.userId ?? update?.user_id));
        },
        MESSAGE_CREATE(event: any) { recordSeen(event?.message?.author?.id ?? event?.author?.id); },
        VOICE_STATE_UPDATES(event: any) { (event?.voiceStates ?? []).forEach((state: any) => recordSeen(state?.userId ?? state?.user_id)); },
        TYPING_START(event: any) { recordSeen(event?.userId ?? event?.user_id); },
        MESSAGE_REACTION_ADD(event: any) { recordSeen(event?.userId ?? event?.user_id); }
    },
    start() { void ensureCacheLoaded(); },
    stop() {
        if (saveTimer) {
            clearTimeout(saveTimer);
            saveTimer = null;
            void DataStore.set(STORAGE_KEY, entries).catch(error => logger.error("Failed to flush activity timestamps", error));
        }
        listeners.clear();
    }
});
